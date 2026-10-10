#!/usr/bin/env bash
# Update bifrost from a local checkout.
#
#   scripts/update-local.sh [--allow-dirty] [--no-sync] [--no-push]
#                           [--force-reset] [branch]
#                           [-- install-local args...]
#
# Upstream (maximhq/bifrost) is always read from its `dev` branch.
# <branch> (default: ynsr/dev) is the fork working branch: it is created
# from origin/dev (ynsr) if missing so fork-specific commits are preserved,
# then rebased onto upstream/dev and pushed to origin. With --force-reset,
# origin/dev is afterwards reset to exactly upstream/dev (fork-only
# commits on dev are discarded — they live on <branch>).
# Finally <branch> is fast-forward pulled from origin and reinstalled via
# scripts/install-local.sh in binary mode.
# Extra args after `--` are forwarded to install-local.sh.
#
# Examples:
#   scripts/update-local.sh
#   scripts/update-local.sh staging
#   scripts/update-local.sh ynsr/dev -- --mode service
#   scripts/update-local.sh --no-sync   # origin only, skip upstream rebase
set -euo pipefail

ALLOW_DIRTY=0
BRANCH="ynsr/dev"
BRANCH_SET=0
INSTALL_ARGS=()
UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/maximhq/bifrost.git"
UPSTREAM_BRANCH="dev"
FORCE_RESET=0
NO_SYNC=0
NO_PUSH=0

usage() {
	cat <<'EOF'
Usage: update-local.sh [--allow-dirty] [--no-sync] [--no-push]
                       [--force-reset]
                       [--upstream-remote NAME] [--upstream-url URL]
                       [--upstream-branch NAME]
                       [branch] [-- install-local args...]

  branch            fork working branch to sync, push, and install
                    (default: ynsr/dev); upstream side is always upstream/dev
  --allow-dirty     proceed even with uncommitted changes (may still fail
                    on checkout/rebase if files conflict)
  --no-sync         skip upstream rebase; update from origin only
  --no-push         rebase locally but do not push the result to origin
  --force-reset     after pushing <branch>, reset origin/dev to exactly
                    upstream/dev (discards fork-only commits on dev)
  --upstream-remote remote name for maximhq/bifrost (default: upstream)
  --upstream-url    URL used when adding the upstream remote
                    (default: https://github.com/maximhq/bifrost.git)
  --upstream-branch upstream branch to sync from (default: dev)
  -- ARGS...        forwarded to scripts/install-local.sh
  -h, --help        show this help

Defaults to binary mode unless --mode is forwarded.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		--allow-dirty)
			ALLOW_DIRTY=1
			shift
			;;
		--no-sync)
			NO_SYNC=1
			shift
			;;
		--no-push)
			NO_PUSH=1
			shift
			;;
		--force-reset)
			FORCE_RESET=1
			shift
			;;
		--upstream-remote)
			UPSTREAM_REMOTE="${2-}"
			[ -n "$UPSTREAM_REMOTE" ] || { printf 'error: --upstream-remote needs a value\n' >&2; exit 1; }
			shift 2
			;;
		--upstream-url)
			UPSTREAM_URL="${2-}"
			[ -n "$UPSTREAM_URL" ] || { printf 'error: --upstream-url needs a value\n' >&2; exit 1; }
			shift 2
			;;
		--upstream-branch)
			UPSTREAM_BRANCH="${2-}"
			[ -n "$UPSTREAM_BRANCH" ] || { printf 'error: --upstream-branch needs a value\n' >&2; exit 1; }
			shift 2
			;;
		--)
			shift
			INSTALL_ARGS+=("$@")
			break
			;;
		-*)
			printf 'error: unknown option: %s\n' "$1" >&2
			usage >&2
			exit 1
			;;
		*)
			if [ "$BRANCH_SET" -eq 0 ]; then
				BRANCH="$1"
				BRANCH_SET=1
				shift
			else
				printf 'error: unexpected argument: %s\n' "$1" >&2
				usage >&2
				exit 1
			fi
			;;
	esac
done

step() { printf '\n▶ %s\n' "$1"; }
done_step() { printf '✓ %s\n' "$1"; }

if [ -n "${BIFROST_REPO_ROOT-}" ]; then
	REPO_ROOT="$BIFROST_REPO_ROOT"
else
	SCRIPT_PATH="${BASH_SOURCE[0]}"
	while [ -L "$SCRIPT_PATH" ]; do
		LINK_TARGET=$(readlink "$SCRIPT_PATH")
		case "$LINK_TARGET" in
			/*) SCRIPT_PATH="$LINK_TARGET" ;;
			*) SCRIPT_PATH="$(dirname -- "$SCRIPT_PATH")/$LINK_TARGET" ;;
		esac
	done
	REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$SCRIPT_PATH")/.." && pwd -P)
fi
cd "$REPO_ROOT"

git rev-parse --git-dir >/dev/null 2>&1 ||
	{ printf 'error: not a git checkout: %s\n' "$REPO_ROOT" >&2; exit 1; }

# Pin fetching to the minimum: upstream (maximhq) tracks only
# $UPSTREAM_BRANCH, origin (ynsr) tracks only dev and $BRANCH, and neither
# remote auto-follows tags — so no other branch or tag is ever fetched.
# Stale remote-tracking refs are deleted outright.
if git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
	step "upstream remote: $UPSTREAM_REMOTE ($(git remote get-url "$UPSTREAM_REMOTE"))"
else
	step "add $UPSTREAM_REMOTE remote ($UPSTREAM_URL)"
	git remote add -t "$UPSTREAM_BRANCH" "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi
git config "remote.$UPSTREAM_REMOTE.fetch" "+refs/heads/$UPSTREAM_BRANCH:refs/remotes/$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git config "remote.$UPSTREAM_REMOTE.tagopt" "--no-tags"
git config remote.origin.tagopt "--no-tags"
git for-each-ref --format='%(refname)' "refs/remotes/$UPSTREAM_REMOTE/" |
	while IFS= read -r ref; do
		case "$ref" in
			"refs/remotes/$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" | "refs/remotes/$UPSTREAM_REMOTE/HEAD") ;;
			*) git update-ref -d "$ref" ;;
		esac
	done
step "fetch $UPSTREAM_REMOTE/$UPSTREAM_BRANCH (other branches + tags excluded)"
git fetch --prune --no-tags "$UPSTREAM_REMOTE" "+refs/heads/$UPSTREAM_BRANCH:refs/remotes/$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git for-each-ref --format='%(refname)' refs/remotes/origin/ |
	while IFS= read -r ref; do
		case "$ref" in
			refs/remotes/origin/dev | "refs/remotes/origin/$BRANCH" | refs/remotes/origin/HEAD) ;;
			*) git update-ref -d "$ref" ;;
		esac
	done
step "fetch origin (dev + $BRANCH only, no tags)"
git fetch --prune --no-tags origin "+refs/heads/dev:refs/remotes/origin/dev" "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"

if [ "$ALLOW_DIRTY" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
	printf 'error: working tree is dirty; commit, stash, or pass --allow-dirty\n' >&2
	git status --short >&2
	exit 1
fi

ensure_branch() {
	# ensure_branch <name> <fallback-ref>: checkout existing local branch,
	# track origin/<name>, or create it at <fallback-ref>.
	local name="$1" fallback="$2"
	if git show-ref --verify --quiet "refs/heads/$name"; then
		git checkout "$name"
	elif git show-ref --verify --quiet "refs/remotes/origin/$name"; then
		git checkout --track "origin/$name"
	elif git rev-parse --verify --quiet "$fallback" >/dev/null; then
		printf 'warning: no local or origin branch named %s; creating at %s\n' "$name" "$fallback" >&2
		git checkout -B "$name" "$fallback"
	else
		printf 'error: no local or origin branch named %s (and fallback %s missing)\n' "$name" "$fallback" >&2
		exit 1
	fi
}

UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

if [ "$BRANCH" = "dev" ] && [ "$FORCE_RESET" -eq 1 ]; then
	printf 'error: --force-reset cannot target dev itself; pass a fork branch (e.g. ynsr/dev)\n' >&2
	exit 1
fi

# Local dev stays a clean mirror of upstream; fork work lives on $BRANCH.
# A divergent local dev (fork commits) is expected here: hard-reset to the
# freshly fetched upstream ref instead of failing on --ff-only.
if [ "$NO_SYNC" -eq 0 ]; then
	step "update local dev to $UPSTREAM_REF"
	ensure_branch dev "$UPSTREAM_REF"
	git reset --hard "$UPSTREAM_REF"
	done_step "dev at $(git rev-parse --short HEAD)"
fi
if [ "$BRANCH" != "dev" ]; then
	step "checkout $BRANCH"
	# New fork branches start from origin/dev (ynsr) so fork-specific
	# commits are preserved, then get rebased onto upstream/dev below.
	ensure_branch "$BRANCH" "origin/dev"
fi

print_manual_recovery() {
	# print_manual_recovery <upstream-ref>: context for hand-resolving a
	# conflict after the rebase was aborted and the branch is unchanged.
	local ref="$1" files commit
	printf '\nerror: rebase onto %s failed; aborted, local branch unchanged\n' "$ref" >&2
	printf '\nConflicted files:\n' >&2
	git diff --name-only --diff-filter=U >&2 || true
	files=$(git diff --name-only --diff-filter=U || true)
	if [ -n "$files" ]; then
		printf '\nWhat upstream changed in those files:\n' >&2
		while IFS= read -r commit; do
			[ -n "$commit" ] || continue
			git log --oneline "$ref" -- "$commit" | head -5 >&2
		done <<EOFILES
$files
EOFILES
	fi
	printf '\nWhat your branch changed (commits being replayed):\n' >&2
	git log --oneline "$ref..HEAD" | head -10 >&2
	cat >&2 <<'EOFSTEPS'

To resolve manually:
  1. git checkout -b resolve/ynsr-dev-<date>   # never resolve on ynsr/dev directly
  2. git rebase <upstream-ref>            # reproduce the conflict
  3. edit markers, git add <files>, git rebase --continue
     (or `git checkout --theirs -- <file>` if upstream already did it,
      `git rebase --skip` if your commit is now obsolete)
  4. git checkout ynsr/dev && git reset --hard resolve/ynsr-dev-<date>
  5. re-run scripts/update-local.sh
EOFSTEPS
}

if [ "$NO_SYNC" -eq 0 ]; then
	step "rebase $BRANCH onto $UPSTREAM_REF"
	BEFORE=$(git rev-parse HEAD)
	if git rebase "$UPSTREAM_REF"; then
		AFTER=$(git rev-parse HEAD)
		if [ "$BEFORE" != "$AFTER" ] && [ "$NO_PUSH" -eq 0 ]; then
			step "push rebased $BRANCH to origin (updates fork)"
			git push --force-with-lease origin "$BRANCH"
			PUSHED=1
		else
			PUSHED=0
		fi
	else
		git rebase --abort || true
		print_manual_recovery "$UPSTREAM_REF"
		exit 1
	fi
else
	PUSHED=0
fi

if [ "$NO_PUSH" -eq 0 ] && [ "$PUSHED" -eq 0 ] \
	&& git show-ref --verify --quiet "refs/remotes/origin/$BRANCH" \
	&& [ "$(git rev-parse "origin/$BRANCH")" != "$(git rev-parse HEAD)" ]; then
	if git merge-base --is-ancestor "origin/$BRANCH" HEAD; then
		step "push $BRANCH to origin (updates fork)"
		git push origin "$BRANCH"
	elif git merge-base --is-ancestor "$UPSTREAM_REF" HEAD \
		&& OLD_BASE=$(git merge-base "origin/$BRANCH" "$UPSTREAM_REF") \
		&& [ -n "$OLD_BASE" ] \
		&& diff <(git diff -U0 --no-color --no-ext-diff "$OLD_BASE" "$UPSTREAM_REF" | grep -v '^index \|^@@ ') \
			<(git diff -U0 --no-color --no-ext-diff "origin/$BRANCH" HEAD | grep -v '^index \|^@@ ') >/dev/null; then
		# Stale remote from an earlier rebase whose push never landed:
		# the origin→HEAD change equals the old-base→upstream change
		# (modulo hunk headers), so force-push loses no fork content.
		step "push $BRANCH to origin (rebased, remote stale)"
		git push --force-with-lease origin "$BRANCH"
		PUSHED=1
	fi
fi

# Push-then-reset: ynsr/dev is safe on origin before origin/dev is mirrored.
if [ "$FORCE_RESET" -eq 1 ] && [ "$NO_SYNC" -eq 0 ] && [ "$NO_PUSH" -eq 0 ]; then
	step "reset origin/dev to $UPSTREAM_REF (exact mirror)"
	git push --force-with-lease=refs/heads/dev:origin/dev origin "$UPSTREAM_REF:refs/heads/dev"
	git fetch --prune --no-tags origin "+refs/heads/dev:refs/remotes/origin/dev"
	done_step "origin/dev mirrors $UPSTREAM_REF"
elif [ "$FORCE_RESET" -eq 1 ] && [ "$NO_SYNC" -eq 1 ]; then
	printf 'warning: --force-reset needs upstream sync; skipping reset (--no-sync)\n' >&2
elif [ "$FORCE_RESET" -eq 1 ] && [ "$NO_PUSH" -eq 1 ]; then
	printf 'warning: --force-reset implies pushing; skipping reset (--no-push)\n' >&2
fi

if [ "$NO_PUSH" -eq 1 ] && [ "$PUSHED" -eq 0 ] \
	&& git show-ref --verify --quiet "refs/remotes/origin/$BRANCH" \
	&& [ "$(git rev-parse "origin/$BRANCH")" != "$(git rev-parse HEAD)" ] \
	&& ! git merge-base --is-ancestor "origin/$BRANCH" HEAD; then
	printf 'warning: local %s diverged from origin/%s after rebase; skipping pull (--no-push)\n' "$BRANCH" "$BRANCH" >&2
	done_step "synced to $(git rev-parse --short HEAD) (not pushed, not pulled)"
else
	step "pull origin/$BRANCH"
	git pull --ff-only --no-tags origin "$BRANCH"
	done_step "updated to $(git rev-parse --short HEAD)"
fi

# Default to binary mode unless the caller overrides --mode.
HAS_MODE=0
for arg in ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}; do
	if [ "$arg" = "--mode" ]; then
		HAS_MODE=1
		break
	fi
done
if [ "$HAS_MODE" -eq 0 ]; then
	INSTALL_ARGS=(--mode binary ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"})
fi
step "install (${INSTALL_ARGS[*]})"
exec "$REPO_ROOT/scripts/install-local.sh" "${INSTALL_ARGS[@]}"
