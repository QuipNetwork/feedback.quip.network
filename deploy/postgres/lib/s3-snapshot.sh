#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Store-agnostic S3 snapshot helpers for the Quip bootnode tooling: publish,
# list, fetch and prune archive-DB snapshots. Sourced by the snapshotter
# snapshot loop (snapshotter-bootstrap.sh) and the bootnode restore-on-boot
# step (akash-bootstrap.sh). Functions only — sourcing has no side effects.
#
# Backend-neutral by design: driven entirely by S3_* env, never Storj-specific
# names, so the backend (Storj today; Garage/MinIO/R2 later) is swappable by
# config alone. Everything routes through `aws --endpoint-url "$S3_ENDPOINT"`.
#
#   S3_ENDPOINT    S3 gateway URL (e.g. https://gateway.storjshare.io)
#   S3_BUCKET      bucket name
#   S3_ACCESS_KEY  access key id   (mapped to AWS_ACCESS_KEY_ID)
#   S3_SECRET_KEY  secret key      (mapped to AWS_SECRET_ACCESS_KEY)
#   S3_REGION      default us-east-1 (Storj ignores it; MinIO expects it)
#   S3_PREFIX      key namespace, default "snapshots/"
#
# Object layout makes "match genesis + reset-version" a pure PREFIX listing and
# "newest" a lexical sort (the UTC timestamp leads the filename), so neither
# the snapshot loop nor restore parses fragile filenames:
#
#   <prefix><chain>/g-<genesis12>/rv-<reset>/snap-<utc-ts>-spec<spec>-h<height>.tar.gz
#
# Tags (genesis/spec/height/reset) are ALSO written as x-amz-meta-* object
# metadata for introspection — NOT S3 object tags, which aren't portable
# (Garage has no PutObjectTagging; user metadata is universal).
#
# Every function is best-effort: it returns the underlying status but never
# `exit`s, so a long-lived caller under relaxed errexit survives a transient
# S3 blip and logs/falls through on its own terms.

S3_REGION="${S3_REGION:-us-east-1}"
S3_PREFIX="${S3_PREFIX:-snapshots/}"

# Exit status s3_list uses for "the listing FAILED" (as opposed to "the listing
# succeeded and the bucket is empty"). Both produce empty stdout, and callers that
# must not mistake a gateway outage for "no snapshot exists" need to tell them
# apart. This is deliberately the RETURN STATUS and not a global: s3_list is
# almost always invoked inside a pipeline and/or a command substitution — i.e. a
# SUBSHELL — so any variable it sets is discarded before the caller can read it,
# whereas the exit status propagates out of both.
S3_RC_LIST_FAILED=3

# Transfer tuning. The AWS CLI has NO env var for multipart chunk size, so we
# materialize a tiny dedicated config and point aws at it via AWS_CONFIG_FILE
# (never touches the caller's ~/.aws/config). Larger chunks = fewer parts =
# fewer chances for a flaky gateway link to drop a part mid-upload; Storj also
# recommends ~64 MB to keep its segment count/cost down. All env-overridable.
S3_MULTIPART_CHUNKSIZE="${S3_MULTIPART_CHUNKSIZE:-64MB}"
S3_MULTIPART_THRESHOLD="${S3_MULTIPART_THRESHOLD:-64MB}"
S3_MAX_CONCURRENCY="${S3_MAX_CONCURRENCY:-4}"
S3_AWS_CONFIG_FILE="${S3_AWS_CONFIG_FILE:-/tmp/quip-aws-config}"

# Restore disk pre-flight: required free space as a percentage of the COMPRESSED
# object size. The archive expands roughly 1.2x (a 32.5 GiB object produced a
# ~39 GiB DB, measured 2026-07-30 — RocksDB SSTs are already compressed, so gzip
# buys little), and the extract lands in a staging dir NEXT TO the existing DB
# because we never delete before a replacement is committed. 150 covers the
# expansion plus filesystem overhead. Set 0 to skip the check entirely.
RESTORE_FREE_FACTOR_PCT="${RESTORE_FREE_FACTOR_PCT:-150}"

# ── Pure helpers (no I/O — unit-tested directly without a backend) ───────────

# snapshot_restore_enabled -> success when SNAPSHOT_RESTORE_ENABLE asks for a
# restore-on-boot. Unset/empty is OFF (the documented default in .env.example),
# and so are the explicit falsy spellings 0/false/no/off, case-insensitively.
#
# WHY THIS EXISTS: every gate used to be a bare `[ -n "${SNAPSHOT_RESTORE_ENABLE:-}" ]`,
# which reads the string "0" as ENABLED because it is non-empty. On 2026-07-30 an
# operator set =0 specifically to stop the snapshotter re-seeding a bloated DB
# from its own snapshot; the flag did nothing, and only a separate populated-DB
# guard prevented the wipe being undone. Setting a flag to 0 must turn it off.
#
# Any OTHER non-empty value stays ON, so existing `=1` deployments are unchanged
# and a typo can never silently disable disaster recovery.
snapshot_restore_enabled() {
    case "$(printf '%s' "${SNAPSHOT_RESTORE_ENABLE:-}" | tr '[:upper:]' '[:lower:]')" in
        ''|0|false|no|off) return 1 ;;
        *)                 return 0 ;;
    esac
}

# _g12 "0xA139beef…" -> "a139beef…" first 12 hex chars, lowercased, 0x stripped.
_g12() {
    local g="${1:-}"
    g="${g#0x}"; g="${g#0X}"
    printf '%s' "$g" | tr 'A-F' 'a-f' | cut -c1-12
}

# snapshot_prefix CHAIN GENESIS RESET -> the listing/match prefix (trailing /).
# A bootnode restore lists exactly this to find candidates; the snapshot loop
# prunes within exactly this. genesis + reset-version are encoded as path
# components so the match is a prefix, never a filename parse.
snapshot_prefix() {
    local chain="$1" genesis="$2" reset="$3"
    printf '%s%s/g-%s/rv-%s/' "$S3_PREFIX" "$chain" "$(_g12 "$genesis")" "$reset"
}

# snapshot_object_key CHAIN GENESIS RESET SPEC HEIGHT TS -> full object key.
# TS is a UTC stamp (e.g. 20260622-101500) and leads the filename so a lexical
# `sort -r` within a prefix yields newest-first.
snapshot_object_key() {
    local chain="$1" genesis="$2" reset="$3" spec="$4" height="$5" ts="$6"
    printf '%ssnap-%s-spec%s-h%s.tar.gz' \
        "$(snapshot_prefix "$chain" "$genesis" "$reset")" "$ts" "$spec" "$height"
}

# _prune_targets K  (keys on stdin)  -> keys to DELETE (all but the newest K).
# Newest-first via lexical sort -r (TS leads each filename). Blank lines and a
# literal "None" (empty list-objects-v2 result) are dropped.
#
# The trailing `|| true` is LOAD-BEARING, not defensive tidying. On EMPTY input
# `grep -v` matches nothing and exits 1; under `pipefail` that becomes the whole
# pipeline's status, and callers capture this as `x="$(s3_list … | _prune_targets)"`
# — a failing command substitution in an assignment, which `set -e` treats as
# fatal. An empty bucket would therefore KILL the caller (the flux bootstrap
# runs `set -Eeuo pipefail`) instead of falling through to genesis sync as every
# comment here promises. "No keys" is a NORMAL result; say so in the status.
_prune_targets() {
    local k="${1:-4}"
    grep -v -e '^$' -e '^None$' | sort -r | tail -n "+$((k + 1))" || true
}

# _newest_key  (keys on stdin)  -> the single newest key (empty if none).
# `|| true` for the same reason as _prune_targets above — this is the one that
# bit production: restore_from_snapshot's `key="$(s3_list "$pfx" | _newest_key)"`
# aborted the bootstrap on a cold start with an empty/unreachable bucket.
_newest_key() {
    grep -v -e '^$' -e '^None$' | sort -r | head -1 || true
}

# ── Backend I/O (thin aws wrappers) ─────────────────────────────────────────

# Materialize the transfer-tuning config once (idempotent). Best-effort: if the
# path isn't writable, aws simply falls back to its 8 MB-chunk defaults.
_aws_ensure_config() {
    [ -s "$S3_AWS_CONFIG_FILE" ] && return 0
    {
        printf '[default]\n'
        printf 's3 =\n'
        printf '    multipart_threshold = %s\n'      "$S3_MULTIPART_THRESHOLD"
        printf '    multipart_chunksize = %s\n'      "$S3_MULTIPART_CHUNKSIZE"
        printf '    max_concurrent_requests = %s\n'  "$S3_MAX_CONCURRENCY"
    } > "$S3_AWS_CONFIG_FILE" 2>/dev/null || true
}

# Run aws against the configured endpoint with creds injected from S3_* env.
#
# AWS_MAX_ATTEMPTS + AWS_RETRY_MODE=standard make botocore retry transient
# failures (SSL "EOF occurred in violation of protocol", connection resets — all
# classified retryable) up to 10 attempts PER request. On an `aws s3 cp <file>`
# that means a dropped multipart part is re-sent (re-read from the seekable file)
# without re-uploading the completed parts — the core of the streaming-upload fix.
#
# AWS_CONFIG_FILE points at our generated transfer-tuning config (chunk size has
# no env var). Creds/region come from env and take precedence regardless.
#
# AWS_*_CHECKSUM_*=when_required disables the default data-integrity checksum
# that AWS CLI v2 / botocore added in early 2025 (botocore >=1.36). That default
# sends an `aws-chunked` streaming body with NO Content-Length, which gateways
# that require Content-Length (Storj, Backblaze B2, some MinIO builds) reject with
# "MissingContentLength". `when_required` reverts to classic Content-Length
# requests. (No-op on the image's awscli 2.9.19 / botocore ~1.29, which predates
# the change — kept for forward-compat and newer clients running the smoke.)
_aws() {
    _aws_ensure_config
    AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY:-}" \
    AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY:-}" \
    AWS_DEFAULT_REGION="$S3_REGION" \
    AWS_CONFIG_FILE="$S3_AWS_CONFIG_FILE" \
    AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}" \
    AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}" \
    AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}" \
    AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}" \
    aws --endpoint-url "${S3_ENDPOINT:-}" "$@"
}

# s3_configured -> 0 if endpoint + bucket + creds are all present.
s3_configured() {
    [ -n "${S3_ENDPOINT:-}" ] && [ -n "${S3_BUCKET:-}" ] \
        && [ -n "${S3_ACCESS_KEY:-}" ] && [ -n "${S3_SECRET_KEY:-}" ]
}

# s3_put KEY FILE [k=v ...] -> upload FILE to KEY, extra args become x-amz-meta.
# aws s3 cp auto-multiparts large objects; metadata is a comma-joined k=v list
# (values must be comma-free — genesis/spec/height/reset all are).
s3_put() {
    local key="$1" file="$2"; shift 2
    local md=""
    local kv
    for kv in "$@"; do md="${md:+$md,}$kv"; done
    if [ -n "$md" ]; then
        _aws s3 cp "$file" "s3://${S3_BUCKET}/${key}" --only-show-errors --metadata "$md"
    else
        _aws s3 cp "$file" "s3://${S3_BUCKET}/${key}" --only-show-errors
    fi
}

# s3_list PREFIX -> newline-separated object keys under PREFIX (empty if none).
# `--output text` prints the literal "None" for an empty result set; strip it
# (and blank lines) so callers get a genuinely empty list, not a phantom key.
s3_list() {
    local prefix="$1" _out _rc
    # Capture aws's own exit code so a transient list/auth error is NOT silently
    # indistinguishable from an empty result set — that ambiguity would let restore
    # fall through to a ~50-min genesis sync with no signal (QUI-767). Still emits
    # empty stdout (callers treat it as "no snapshot", non-fatal) but LOGS the real
    # fault AND returns $S3_RC_LIST_FAILED so a caller can retry rather than concede.
    #
    # ⚠ Callers under `set -e` must guard the non-zero return (`|| true`, or capture
    # it with `_out="$(s3_list …)" || rc=$?`); it is NOT a fatal error, it is a
    # distinguishable one.
    #
    # `2>/dev/null` silences aws, but it does NOT silence an inherited ERR trap:
    # with `set -E` the caller's trap fires INSIDE this command substitution, and
    # any trap that prints to STDOUT lands in $_out. Hence the sanity filter on
    # the way out — see the grep below.
    _out="$(_aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$prefix" \
        --query 'Contents[].Key' --output text 2>/dev/null)"; _rc=$?
    if [ "$_rc" -ne 0 ]; then
        printf '[s3-snapshot] WARN: s3_list failed (rc=%s) for prefix %s — treating as EMPTY; a restore may fall through to genesis sync\n' \
            "$_rc" "$prefix" >&2
        return "$S3_RC_LIST_FAILED"
    fi
    # Emit only keys that actually START WITH the requested prefix. A real listing
    # can only ever return those, so this costs nothing on the happy path while
    # containing any foreign text that reached $_out (an inherited ERR-trap line, an
    # aws notice on stdout) instead of passing it off as an object key.
    # awk index()==1 rather than `grep "^$prefix"`: prefixes carry regex
    # metacharacters (`rv-v0.2-preview-3` has dots), so a regex would be both
    # wrong-by-luck and unanchored to literal text. index() is an exact substring
    # test and ==1 anchors it to the start.
    printf '%s\n' "$_out" | tr '\t' '\n' | grep -v -e '^None$' -e '^$' \
        | awk -v p="$prefix" 'index($0, p) == 1' || true
}

# s3_put_stream KEY [k=v ...] -> upload stdin to KEY (no local temp file).
# The production path: `tar -cz … | s3_put_stream …` streams the archive DB
# straight to S3, so the snapshot never needs free space on the PVC (which the
# DB itself is filling). aws s3 cp multiparts a non-seekable stdin.
s3_put_stream() {
    local key="$1"; shift
    local md="" kv
    for kv in "$@"; do md="${md:+$md,}$kv"; done
    if [ -n "$md" ]; then
        _aws s3 cp - "s3://${S3_BUCKET}/${key}" --metadata "$md"
    else
        _aws s3 cp - "s3://${S3_BUCKET}/${key}"
    fi
}

# s3_get KEY DEST -> download one object to a file (--only-show-errors keeps the
# container lease-logs clean; the per-part progress bar would otherwise flood).
s3_get() {
    _aws s3 cp "s3://${S3_BUCKET}/${1}" "$2" --only-show-errors
}

# s3_get_stream KEY -> stream one object to stdout (no local temp file).
# The restore path: `s3_get_stream … | tar -xz -C /data`.
s3_get_stream() {
    _aws s3 cp "s3://${S3_BUCKET}/${1}" -
}

# s3_object_ok KEY -> 0 iff the object exists with a non-zero ContentLength. A
# cheap post-upload durability check (one head-object, no download) used to GATE
# pruning: the snapshot loop must never delete older snapshots on the strength of
# an upload it can't confirm actually landed. A truncated/failed-but-reported-ok
# stream would otherwise let s3_prune age out the last good snapshot. This does
# NOT verify the DB opens (that needs a full download — see the out-of-band
# restore-smoke); it only proves an object of real size is present.
s3_object_ok() {
    local key="${1:-}" len
    [ -n "$key" ] || return 1
    len="$(_aws s3api head-object --bucket "$S3_BUCKET" --key "$key" \
            --query 'ContentLength' --output text 2>/dev/null)" || return 1
    [ -n "$len" ] && [ "$len" != "None" ] && [ "$len" -gt 0 ] 2>/dev/null
}

# s3_object_size KEY -> ContentLength in bytes on stdout; non-zero if unreadable.
# Split out of s3_object_ok so the restore disk pre-flight can size an object
# without downloading it.
s3_object_size() {
    local key="${1:-}" len
    [ -n "$key" ] || return 1
    len="$(_aws s3api head-object --bucket "$S3_BUCKET" --key "$key" \
            --query 'ContentLength' --output text 2>/dev/null)" || return 1
    case "$len" in ''|None|*[!0-9]*) return 1 ;; esac
    printf '%s' "$len"
}

# s3_prune PREFIX K -> keep the newest K objects under PREFIX, delete the rest.
s3_prune() {
    local prefix="$1" k="${2:-4}" old
    # `|| true`: s3_list returns $S3_RC_LIST_FAILED on a transport fault, which
    # pipefail would surface as the pipeline's status and `set -e` would take as
    # fatal. A failed listing yields no keys, so pruning correctly does nothing —
    # and NOT pruning is always the safe direction (the alternative is deleting
    # snapshots on the strength of a listing we could not actually read).
    old="$(s3_list "$prefix" | _prune_targets "$k" || true)"
    [ -z "$old" ] && return 0
    local key
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        _aws s3 rm "s3://${S3_BUCKET}/${key}" >/dev/null 2>&1 \
            || printf '[s3-snapshot] WARN: prune failed for %s\n' "$key" >&2
    done <<< "$old"
}

# s3_abort_orphans [PREFIX] -> abort every in-progress (incomplete) multipart
# upload under PREFIX (default S3_PREFIX). Why this is necessary: Storj BILLS
# incomplete multipart uploads against storage, never auto-expires them, and its
# gateway does NOT support lifecycle AbortIncompleteMultipartUpload — and
# `aws s3 cp` only aborts on an IN-PROCESS failure, so a hard connection/host
# death (exactly an SSL-EOF) orphans the already-uploaded parts. We therefore
# sweep explicitly on every failed upload and as a one-time cleanup. Best-effort;
# always returns 0. (Storj's ListMultipartUploads is "partial" support — treat
# the listing as best-effort and re-run if needed.)
s3_abort_orphans() {
    local prefix="${1:-$S3_PREFIX}" out key uid n=0
    out="$(_aws s3api list-multipart-uploads --bucket "$S3_BUCKET" --prefix "$prefix" \
            --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null)" || return 0
    [ -z "$out" ] && return 0
    while IFS=$'\t' read -r key uid; do
        if [ -z "$key" ] || [ -z "$uid" ] || [ "$key" = "None" ]; then continue; fi
        if _aws s3api abort-multipart-upload --bucket "$S3_BUCKET" --key "$key" \
                --upload-id "$uid" >/dev/null 2>&1; then
            n=$((n + 1))
        else
            printf '[s3-snapshot] WARN: abort failed for %s (upload-id %s)\n' "$key" "$uid" >&2
        fi
    done <<< "$out"
    [ "$n" -gt 0 ] && printf '[s3-snapshot] aborted %s incomplete multipart upload(s) under %s\n' "$n" "$prefix" >&2
    return 0
}

# ── Restore (shared by the bootnode boot AND the snapshotter boot) ───────────

# Stay-awake placeholder listener (best-effort). restore_from_snapshot blocks for
# many minutes streaming + extracting the archive DB, during which NOTHING is
# bound on the pod. Some providers restart a pod that never starts listening, so
# we hold a throwaway TCP listener on RESTORE_KEEPALIVE_PORT for the restore's
# duration and free it before substrate (or the bootnode's key-insert/exec) binds
# the real port. Nothing ever dials it — the snapshotter never sets --public-addr,
# and the bootnode hasn't started substrate yet. No-op unless RESTORE_KEEPALIVE_PORT
# is set AND `nc` is present, so unit tests / non-Akash contexts skip it; the
# bootstrap callers export the port (30333) right before invoking restore.
RESTORE_KEEPALIVE_PID=""
_restore_open_keepalive() {
    RESTORE_KEEPALIVE_PID=""
    local port="${RESTORE_KEEPALIVE_PORT:-}"
    [ -n "$port" ] || return 0
    case "$port" in *[!0-9]*) printf '[restore] keepalive: non-numeric port %s; skipping\n' "$port" >&2; return 0 ;; esac
    if ! command -v nc >/dev/null 2>&1; then
        printf '[restore] keepalive: nc unavailable; not holding :%s placeholder\n' "$port" >&2
        return 0
    fi
    # Respawn-supervised placeholder: a bare `nc -l -k` that crashes/OOMs under a heavy
    # multi-minute restore leaves :port UNBOUND, and some providers kill a non-listening
    # pod — a restart that re-streams the whole archive from zero (QUI-767 Raleigh). Run
    # the listener in a respawn loop inside its OWN session (setsid) so the whole group
    # (supervisor + nc) can be reaped at close with one `kill -- -PGID` (the image has no
    # pkill/pgrep). netcat-openbsd: -l listen, -k keep accepting across connects.
    setsid bash -c "while :; do nc -l -k ${port} >/dev/null 2>&1; sleep 1; done" >/dev/null 2>&1 &
    RESTORE_KEEPALIVE_PID=$!
    printf '[restore] keepalive: holding placeholder TCP :%s during restore (respawn-supervised, pgid=%s)\n' "$port" "$RESTORE_KEEPALIVE_PID" >&2
}
_restore_close_keepalive() {
    [ -n "$RESTORE_KEEPALIVE_PID" ] || return 0
    # setsid made the supervisor a group leader (pgid == pid), so kill the whole group —
    # stops the respawn loop AND frees the port before substrate/the exec binds it. Fall
    # back to a bare-pid kill if the group signal is rejected.
    kill -TERM -- "-${RESTORE_KEEPALIVE_PID}" 2>/dev/null || kill "$RESTORE_KEEPALIVE_PID" 2>/dev/null
    # `|| true`: we just SIGTERMed it, so `wait` reporting 143 is the SUCCESS case.
    # Without this it trips the caller's ERR trap and errexit — the bootstrap logged
    # a bogus "ERR: rc=143 at line …: wait" on every single restore, which reads as
    # a fault in exactly the log an operator scans after a failed restore.
    wait "$RESTORE_KEEPALIVE_PID" 2>/dev/null || true
    printf '[restore] keepalive: released placeholder TCP listener (pgid=%s)\n' "$RESTORE_KEEPALIVE_PID" >&2
    RESTORE_KEEPALIVE_PID=""
}

# restore_from_snapshot CHAIN GENESIS RESET -> best-effort restore of the newest
# matching snapshot into the data dir (SNAPSHOT_DATA_DIR, default /data), ONLY
# on a FRESH PVC. Always returns 0 (restore is non-fatal; the caller falls
# through to genesis sync on any miss). It is a NO-OP when the data dir is
# already populated (never clobbers an in-place restart's DB) or when no
# snapshot matches. Strict match: genesis (first 12 hex) + reset-version, newest
# by the leading timestamp. `local -` localizes errexit so a transient S3 blip
# here can never abort a caller running under `set -e`; pipefail is inherited so
# the stream/extract `if` still detects a failed download.
#
# RESTART-SAFE: extraction is staged in chains.restore-tmp and the restored chain
# dir is committed into place with a single atomic rename. So chains/<sub>/db (the
# ONLY signal the never-clobber guard reads) appears all-at-once on success and
# NEVER as a partial — a pod killed mid-extract leaves nothing in the live dir, so
# the next boot re-attempts the restore instead of seeing a half-extract as
# "already populated" and genesis-syncing (the r9 restore bug this fixes).
restore_from_snapshot() {
    local -
    set +e
    local chain="$1" genesis="$2" reset="$3"
    local datadir="${SNAPSHOT_DATA_DIR:-/data}"
    local tmp="$datadir/chains.restore-tmp"
    if ! s3_configured; then
        printf '[restore] WARN: S3 not fully configured (need S3_ENDPOINT/BUCKET/ACCESS_KEY/SECRET_KEY); skipping\n' >&2
        return 0
    fi
    # Never-clobber: skip ONLY when a restore actually COMPLETED here — the
    # .restore-complete marker. SSTs alone are NOT a safe "populated" signal: a
    # partial/corrupt genesis-sync DB has SSTs but never restored (QUI-767: the
    # .233/Tokyo Flux stalls sat on SST-bearing DBs that the old SST-glob guard
    # PRESERVED, so they never re-restored and never reached tip). Any markerless
    # chains/*/db — an empty crash artifact OR a stalled/corrupt genesis-sync DB
    # with real SSTs — is cleared here for a fresh restore. A genuinely restored
    # DB always carries the marker (written on atomic commit below), so 185-class
    # warm DBs are still preserved across in-place restarts.
    # Reclaim a staging dir orphaned by a restore killed mid-extract. This MUST
    # run before the marker early-return below: the cleanup used to sit after it,
    # so once .restore-complete existed the function returned above the cleanup
    # and an orphan — up to a full DB's worth of dead bytes — could never be
    # reclaimed by any later boot. Safe here because restore_from_snapshot is the
    # only writer of this path and never runs concurrently with itself.
    rm -rf "$tmp"
    if [ -f "$datadir/.restore-complete" ]; then
        printf '[restore] %s already populated (restore-complete marker present) — skipping (in-place restart keeps its DB, no resync)\n' "$datadir" >&2
        return 0
    fi
    # No marker. Clear ONLY an EMPTY crash-artifact DB up front (chains/*/db present but
    # no SSTs — a crash-looping node recreates it every launch, and it is worthless, so
    # clearing loses nothing and unblocks re-restore). A POPULATED markerless DB (real
    # SSTs: a genesis-synced or stalled/corrupt DB) is NOT destroyed here — the atomic
    # commit below removes it ONLY when a replacement is downloaded and about to land.
    # So an unset genesis / no matching snapshot / failed download preserves the existing
    # DB instead of leaving an EMPTY one (QUI-767: delete-before-confirm on a markerless-
    # but-good authority DB + a transient S3 blip = empty DB = finality halt on the
    # 3-authority chain). B1 re-heals a stalled STANDBY separately.
    if ls -d "$datadir"/chains/*/db >/dev/null 2>&1 && ! ls "$datadir"/chains/*/db/full/*.sst >/dev/null 2>&1; then
        printf '[restore] WARN: chains/*/db present but EMPTY (no SSTs) — crash artifact; clearing for a fresh restore\n' >&2
        rm -rf "$datadir"/chains
    fi
    if [ -z "$genesis" ]; then
        printf '[restore] WARN: genesis unset — cannot match snapshots safely; falling through to genesis sync\n' >&2
        return 0
    fi
    # (The staging dir was already reclaimed above, before the marker check, so
    # a partial from a killed extract is cleared on EVERY path — not just the
    # ones that reach this far.)

    local pfx key
    pfx="$(snapshot_prefix "$chain" "$genesis" "$reset")"
    printf '[restore] fresh data dir; searching s3://%s/%s\n' "$S3_BUCKET" "$pfx" >&2

    # Retry a FAILED listing before conceding. An empty listing is a fact — concede
    # immediately. A failed one is an unknown, and conceding on it costs a genesis
    # sync that a parked Flux standby never actually completes (2026-08-17: one
    # ~11-min read timeout to the Storj gateway was enough to strand an instance at
    # block #0 indefinitely). Cheap: a few short listings against a multi-minute
    # download, and the happy path takes the first attempt.
    local _lt="${RESTORE_LIST_RETRIES:-3}" _ln=0 _lsleep="${RESTORE_LIST_RETRY_SLEEP:-20}" _raw _lrc
    case "$_lt"     in *[!0-9]*|'') _lt=3      ;; esac
    case "$_lsleep" in *[!0-9]*|'') _lsleep=20 ;; esac
    while :; do
        _ln=$((_ln + 1))
        # Two steps, NOT `s3_list … | _newest_key`: the status we need is s3_list's
        # own, and in a pipeline `pipefail` would blend it with the selector's. The
        # `|| _lrc=$?` guard is what keeps a failed listing non-fatal under `set -e`.
        _lrc=0; _raw="$(s3_list "$pfx")" || _lrc=$?
        key="$(printf '%s\n' "$_raw" | _newest_key)"
        [ -n "$key" ] && break
        [ "$_lrc" -eq "$S3_RC_LIST_FAILED" ] || break   # genuinely empty: stop asking
        if [ "$_ln" -ge "$_lt" ]; then
            printf '[restore] WARN: listing %s FAILED %s/%s times (transport, not an empty bucket) — falling through to genesis sync; a snapshot may well exist\n' \
                "$pfx" "$_ln" "$_lt" >&2
            break
        fi
        printf '[restore] listing failed (attempt %s/%s) — retrying in %ss\n' "$_ln" "$_lt" "$_lsleep" >&2
        sleep "$_lsleep"
    done

    if [ -z "$key" ]; then
        printf '[restore] WARN: no snapshot matching genesis=%s reset=%s; falling through to genesis sync\n' "$genesis" "${reset:-<empty>}" >&2
        return 0
    fi
    # Shape gate. $key becomes an `aws s3 cp` argument, so anything that is not a
    # snapshot object under our own prefix must never get that far. This is why:
    # on 2026-08-17 an inherited ERR trap printed a diagnostic to stdout INSIDE the
    # s3_list command substitution, that line became $key, and the node spent 34
    # minutes trying to download a URL-encoded shell command in three ~11-min
    # attempts. s3_list now filters its own output too; this is the belt to that
    # braces, because the cost of being wrong here is measured in tens of minutes.
    case "$key" in
        "$pfx"snap-*.tar.gz) : ;;
        *)
            printf '[restore] WARN: refusing implausible snapshot key %s (expected %ssnap-*.tar.gz) — falling through to genesis sync\n' \
                "$key" "$pfx" >&2
            return 0
            ;;
    esac

    # ── Disk pre-flight ──────────────────────────────────────────────────────
    # The extract lands in a staging dir NEXT TO the live DB (the atomic commit
    # below only removes the old copy once a replacement is ready), so a restore
    # transiently needs the EXPANDED archive as free space on top of whatever is
    # already there. Running out mid-extract leaves a torn volume and, on a full
    # disk, a node that cannot open its DB at all — the 2026-07-30 incident.
    # Refusing here is strictly better: the existing DB is untouched and the
    # caller falls through exactly as it does for "no matching snapshot".
    # Every path through this block LOGS. An earlier draft used
    # `[ "${VAR:-0}" -gt 0 ] 2>/dev/null`, which returns 2 on a non-numeric value
    # and, as an `if` condition, skipped the check with no output at all — so a
    # typo like RESTORE_FREE_FACTOR_PCT=200% silently disabled the guard while
    # looking like it had raised it.
    local _pf="${RESTORE_FREE_FACTOR_PCT:-0}"
    case "$_pf" in
      ''|0)
        printf '[restore] disk pre-flight disabled (RESTORE_FREE_FACTOR_PCT=%s)\n' \
            "${_pf:-<empty>}" >&2
        ;;
      *[!0-9]*)
        printf '[restore] WARN: RESTORE_FREE_FACTOR_PCT=%s is not a positive integer — skipping the disk pre-flight (set it to 0 to disable deliberately)\n' \
            "$_pf" >&2
        ;;
      *)
        local _objlen _need_kib _avail_kib
        if _objlen="$(s3_object_size "$key")"; then
            _need_kib=$(( _objlen / 1024 * _pf / 100 ))
            _avail_kib="$(df -Pk "$datadir" 2>/dev/null | awk 'NR==2{print $4}')"
            case "$_avail_kib" in ''|*[!0-9]*) _avail_kib="" ;; esac
            if [ -n "$_avail_kib" ] && [ "$_avail_kib" -lt "$_need_kib" ]; then
                printf '[restore] REFUSING: %s needs ~%s MiB free to expand (compressed %s MiB x %s%%), only %s MiB available on %s. Existing DB left untouched — free space or raise the volume, then reboot.\n' \
                    "$key" "$((_need_kib / 1024))" "$((_objlen / 1048576))" \
                    "$_pf" "$((_avail_kib / 1024))" "$datadir" >&2
                return 0
            fi
            printf '[restore] preflight ok: %s MiB free on %s, need ~%s MiB\n' \
                "$(( ${_avail_kib:-0} / 1024 ))" "$datadir" "$((_need_kib / 1024))" >&2
        else
            printf '[restore] WARN: could not size %s (head-object failed) — proceeding WITHOUT the disk pre-flight\n' "$key" >&2
        fi
        ;;
    esac

    # Hold a placeholder listener so a provider that restarts non-listening pods
    # doesn't kill us during the multi-minute download (freed before we return).
    _restore_open_keepalive

    # Stream download + extract into a TEMP staging dir (no compressed temp file —
    # peak disk is just the extracted DB, as before), then commit atomically. A
    # streaming GET can't resume mid-connection, so resilience is retrying the
    # WHOLE download+extract. chains/<sub>/db appears ONLY via the final rename, so
    # a kill before it leaves nothing in the live dir and the next boot re-attempts.
    local tries="${RESTORE_RETRIES:-3}" n=0 ok=0
    while [ "$n" -lt "$tries" ]; do
        n=$((n + 1))
        rm -rf "$tmp"; mkdir -p "$tmp"
        printf '[restore] attempt %s/%s: streaming + extracting %s into %s (staged)\n' "$n" "$tries" "$key" "$tmp" >&2
        if s3_get_stream "$key" | tar -xz -C "$tmp" 2>&1 | sed 's/^/  restore: /' >&2; then
            # Atomic commit: rename each restored chain dir into place (same
            # filesystem). chains/<sub>/db appearing is the single all-or-nothing
            # signal the never-clobber guard reads on a later boot.
            mkdir -p "$datadir/chains"
            local sub name committed=0
            for sub in "$tmp"/chains/*/; do
                [ -d "$sub" ] || continue
                name="$(basename "$sub")"
                rm -rf "$datadir/chains/$name"
                if mv "$sub" "$datadir/chains/$name"; then
                    committed=1
                    # The tarball has no entry for the chain parent dir, so tar
                    # auto-creates it ROOT-owned; the node (gosu quip) must own
                    # what it opens and creates keystores under (QUI-767).
                    chown quip:quip "$datadir/chains" "$datadir/chains/$name" 2>/dev/null \
                        || printf '[restore] WARN: chown quip:quip %s failed (tolerated) — the gosu-quip node may hit RocksDB PermissionDenied opening the restored DB\n' "$datadir/chains" >&2
                fi
            done
            rm -rf "$tmp"
            if [ "$committed" -eq 1 ]; then
                : > "$datadir/.restore-complete" 2>/dev/null \
                    || printf '[restore] WARN: could not write %s/.restore-complete (tolerated) — every future boot will see no marker and RE-DOWNLOAD the full ~38GiB snapshot\n' "$datadir" >&2
                printf '[restore] extracted ok\n' >&2
                ok=1; break
            fi
            printf '[restore] WARN: archive contained no chains/*/ to commit; retrying\n' >&2
        else
            printf '[restore] WARN: attempt %s failed; wiping partial staging dir before retry\n' "$n" >&2
        fi
        rm -rf "$tmp"
    done

    _restore_close_keepalive

    [ "$ok" -eq 1 ] && return 0
    printf '[restore] WARN: all %s attempts failed; falling through to genesis sync\n' "$tries" >&2
    return 0
}
