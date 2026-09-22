#!/usr/bin/env bash
# The coordinator never constructs repository-mutating or production commands.

workflowPolicyRejectCommand() {
	local command_name=${1:-} argument
	if [ "$command_name" = git ]; then
		for argument in "$@"; do
			case "$argument" in
			commit|merge|push|reset|clean|rebase)
				printf 'workflow: forbidden coordinator operation\n' >&2
				return 1
				;;
			esac
		done
	fi
	if [ "$command_name" = supabase ] && [ "${2:-}" = db ] && [ "${3:-}" = push ]; then
		printf 'workflow: forbidden coordinator operation\n' >&2
		return 1
	fi
}

workflowPolicyValidateProfile() {
	case "$1" in
	repository-tests) return 0 ;;
	*) printf 'workflow: unknown validation profile: %s\n' "$1" >&2; return 1 ;;
	esac
}
