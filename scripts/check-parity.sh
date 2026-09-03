#!/bin/sh
#
# marc — report which parts of the Windows port are behind the macOS sources.
#
# For every row in parity.manifest this finds the last commit that touched the
# Windows file, then lists the commits after it that touched any of the macOS
# sources it was ported from. Those commits are the porting task.
#
# Usage:
#   scripts/check-parity.sh              report every stale Windows file
#   scripts/check-parity.sh --since REV  report macOS changes since REV instead
#   scripts/check-parity.sh --files       print only stale paths, for scripting
#
# Exits 0 when the port is current, 1 when anything is stale or unmapped.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST="$ROOT/parity.manifest"
cd "$ROOT"

SINCE=""
FILES_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --since)
            [ $# -ge 2 ] || { echo "--since needs a revision" >&2; exit 2; }
            SINCE=$2
            shift 2
            ;;
        --files)
            FILES_ONLY=1
            shift
            ;;
        -h|--help)
            sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

[ -f "$MANIFEST" ] || { echo "No parity manifest at $MANIFEST" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "Not a git repository" >&2; exit 2; }

if [ -n "$SINCE" ]; then
    git rev-parse --verify --quiet "$SINCE" >/dev/null || {
        echo "Unknown revision: $SINCE" >&2
        exit 2
    }
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/stale"
: >"$TMP/report"
: >"$TMP/mapped"
: >"$TMP/covered"
: >"$TMP/exempt"
: >"$TMP/reviewed"

# --------------------------------------------------------------- directives

# Read every directive first, so that a row's behaviour does not depend on
# where the directive sits in the file.
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '!coverage	'*)
            # !coverage <directory> <find name pattern>
            rest=${line#*	}
            directory=${rest%%	*}
            pattern=${rest#*	}
            [ "$directory" != "$pattern" ] || {
                echo "Malformed !coverage row (expected two fields): $line" >&2
                exit 2
            }
            [ -d "$directory" ] || continue
            find "$directory" -type f -name "$pattern" >>"$TMP/covered"
            continue
            ;;
        '!no-port	'*)
            # !no-port <path> <reason>
            rest=${line#*	}
            echo "${rest%%	*}" >>"$TMP/exempt"
            continue
            ;;
        '!reviewed	'*)
            # !reviewed <windows path> <revision> — the port was checked against
            # this revision and needed no change. Records a decision that no
            # commit would otherwise capture.
            rest=${line#*	}
            reviewed_path=${rest%%	*}
            reviewed_rev=${rest#*	}
            reviewed_rev=${reviewed_rev%%	*}
            [ "$reviewed_path" != "$reviewed_rev" ] || {
                echo "Malformed !reviewed row (expected two fields): $line" >&2
                exit 2
            }
            resolved=$(git rev-parse --verify --quiet "$reviewed_rev^{commit}" || true)
            [ -n "$resolved" ] || {
                echo "!reviewed names an unknown revision: $reviewed_rev" >&2
                exit 2
            }
            printf '%s\t%s\n' "$reviewed_path" "$resolved" >>"$TMP/reviewed"
            continue
            ;;
        '!'*)
            echo "Unknown manifest directive: $line" >&2
            exit 2
            ;;
    esac
done <"$MANIFEST"

# ------------------------------------------------------------------ manifest

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|\#*|'!'*) continue ;;
    esac

    target=${line%%	*}
    sources=${line#*	}
    [ "$target" != "$sources" ] || {
        echo "Malformed row (expected a tab): $line" >&2
        exit 2
    }

    # Record the mapping coverage even for rows we then skip.
    if [ "$sources" != "-" ]; then
        echo "$sources" | tr ',' '\n' >>"$TMP/mapped"
    fi

    [ -e "$target" ] || {
        printf 'MISSING  %s\n         listed in the manifest but not on disk\n\n' "$target" >>"$TMP/report"
        echo "$target" >>"$TMP/stale"
        continue
    }

    [ "$sources" != "-" ] || continue

    # The baseline is the last commit that touched the port, unless --since
    # asked for an explicit range instead.
    if [ -n "$SINCE" ]; then
        base=$SINCE
    else
        base=$(git log -1 --format=%H -- "$target" 2>/dev/null || true)

        # A !reviewed revision counts as a baseline too, so that "looked at it,
        # nothing to change" is recordable without a no-op commit. Whichever of
        # the two is later wins.
        reviewed=$(awk -F'\t' -v path="$target" '$1 == path { print $2 }' "$TMP/reviewed" | tail -1)
        if [ -n "$reviewed" ]; then
            if [ -z "$base" ] || git merge-base --is-ancestor "$base" "$reviewed" 2>/dev/null; then
                base=$reviewed
            fi
        fi

        if [ -z "$base" ]; then
            printf 'UNTRACKED  %s\n           not committed yet, so staleness cannot be determined\n\n' \
                "$target" >>"$TMP/report"
            echo "$target" >>"$TMP/stale"
            continue
        fi
    fi

    # Split the comma-separated sources into positional arguments for git log.
    set --
    for source in $(echo "$sources" | tr ',' ' '); do
        if [ ! -e "$source" ]; then
            printf 'MISSING  %s\n         mapped from %s, which is not on disk\n\n' \
                "$target" "$source" >>"$TMP/report"
        fi
        set -- "$@" "$source"
    done

    commits=$(git log --format='%h %s' "$base..HEAD" -- "$@" 2>/dev/null || true)
    [ -n "$commits" ] || continue

    echo "$target" >>"$TMP/stale"
    count=$(printf '%s\n' "$commits" | wc -l | tr -d ' ')
    {
        printf 'STALE  %s\n' "$target"
        printf '       %s unported commit(s) in %s:\n' "$count" "$sources"
        printf '%s\n' "$commits" | sed 's/^/         /'
        printf '\n'
    } >>"$TMP/report"
done <"$MANIFEST"

# --------------------------------------------------------- mapping coverage

# Without an explicit !coverage directive, scan the Swift sources only.
if [ ! -s "$TMP/covered" ]; then
    find Sources -type f -name '*.swift' >>"$TMP/covered"
fi

# Normalise ./foo and foo to the same path before comparing.
sed 's|^\./||' "$TMP/covered" | sort -u >"$TMP/covered-sorted"
{ sed 's|^\./||' "$TMP/mapped"; sed 's|^\./||' "$TMP/exempt"; } | sort -u >"$TMP/accounted"
unmapped=$(comm -23 "$TMP/covered-sorted" "$TMP/accounted" || true)

if [ -n "$unmapped" ]; then
    {
        printf 'UNMAPPED\n'
        printf '       macOS sources that no manifest row ports:\n'
        printf '%s\n' "$unmapped" | sed 's/^/         /'
        printf '\n'
    } >>"$TMP/report"
fi

# ------------------------------------------------------------------- output

if [ "$FILES_ONLY" -eq 1 ]; then
    [ -s "$TMP/stale" ] || exit 0
    cat "$TMP/stale"
    exit 1
fi

if [ ! -s "$TMP/report" ]; then
    echo "The Windows port is current with every mapped macOS source."
    exit 0
fi

cat "$TMP/report"

stale_count=$(sort -u "$TMP/stale" | wc -l | tr -d ' ')
if [ -n "$unmapped" ]; then
    unmapped_count=$(printf '%s\n' "$unmapped" | wc -l | tr -d ' ')
    printf '%s Windows file(s) to port, %s macOS source(s) unmapped.\n' "$stale_count" "$unmapped_count"
else
    printf '%s Windows file(s) to port.\n' "$stale_count"
fi
printf 'See PORTING.md for how to work through this list.\n'
exit 1
