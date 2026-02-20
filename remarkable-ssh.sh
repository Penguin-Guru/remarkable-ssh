#!/bin/bash


#
##
### Hard-coded globals (for easy access):
##
#


#
## Sync behaviour:
#

declare -a SyncParams=(	## For making either the local cache or (remote) device like the other.
	'--info=progress2'
	'--archive'
	'--checksum'
	## Some options (such as filters) are appended conditionally.
	## See rsync manual section on "TRANSFER RULES" for filter compatibility.
)
declare -a DiffSyncParams=(	## For checking what rsync would do if run.
	'--dry-run'
	'--itemize-changes'
)


#
## Remarkable implementation:
#

declare XochitlDir='/home/root/.local/share/remarkable/xochitl'
## Rm* associative arrays (-A) are accessed through the get_rm_enum function.
declare -A RmFileExt=(	## File types defined by Xochitl.
	[metadata]='metadata'     ## Defines object.
	[content]='content'       ## Defines state of object (e.g. user preferences).
	[local]='local'           ## Meta-content data? ("contentFormatVersion")
	[thumbnails]='thumbnails' ## Thumbnail image(s). Always singular?
	[png]='png'               ## Used for thumbnails in sub-directories?
	[rm]='rm'                 ## "reMarkable .lines file" ("version=6")
	[pagedata]='pagedata'
	[epubindex]='epubindex'
)
declare -A RmObjectType=(	## Object types defined by Xochitl.
	[folder]='CollectionType'
	[document]='DocumentType'
)
declare -a RmSupportedImportFileExt=(	## File types Xochitl can import.
	'pdf'
	'epub'
)



#
##
### Initialisation for function definitions:
##
#


{	## Check for (some) dependencies:
	declare -a Dependencies=(
		'jq'
		'rsync'
		'ssh'
		'find'
		'sed'	## Currently only used in `diff_cache`.
	)
	declare -i failed=0	## Print all, if any, missing dependencies.
	for dep in "${Dependencies[@]}"; do
		if ! command -v "$dep" > /dev/null 2>&1 ; then
			echo "Failed to detect necessary program: \"$dep\"" >&2
			failed=1
		fi
	done
	if ((failed)); then exit 1; fi
}


## Support termination from sub-shells:
trap "exit 1" TERM
export TOP_PID=$$
function terminate() {
	kill -s SIGTERM 0	## Send to all processes in group (see `man 2 kill`).
	## Attempt to prevent async procession.
	if command -v sleep > /dev/null 2>&1 || enable -f sleep sleep ; then
		sleep 2
	else
		wait -f	## Not specifying $TOP_PID, for risk of race condition.
	fi
}



#
##
### Utility functions:
##
#

#
## Validation utility functions:
#

function validate_cache() {
	if [[ -z "$cache" ]]; then
		echo 'Specify local directory for cache.' >&2
	elif [[ ! -d "$cache" ]]; then
		echo "Specified cache directory does not exist: \"$cache\"" >&2
	else
		return 0
	fi
	terminate
}

function validate_host() {
	## Currently, only a simple string not null check is performed.
	if ! get_param 'host' >/dev/null; then
		echo 'Specify S.S.H. host for your Remarkable device.' >&2
		terminate
	fi
}

function validate_string_not_empty() {
	if [[ -z "$1" ]]; then
		if [[ "$2" ]]; then
			echo "$2" >&2
		else
			echo 'Encountered empty string where value is required.' >&2
		fi
		terminate
	fi
}

function is_function_defined() {
	validate_string_not_empty "$1"
	if declare -F "$1" >/dev/null 2>&1; then return 0; fi	## True.
	return 1	## False.
}


#
## Accessor utility functions:
#

function get_param() {
	## $1: Parameter name.
	if [[ ! -v "$1" ]]; then
		return 1
	fi
	echo "$1"	## Empty string may be valid.
	return 0
}
function get_necessary_param() {
	if ! get_param "$1"; then	## Return param name via stdout on success.
		echo "Necessary parameter not defined: \"$1\"" >&2
		terminate
	fi
}

function get_rm_enum() {	## Accessor for Rm* arrays.
	local -n rm_enum="Rm$1"
	local rm_name="$2"
	local var="${!rm_enum}_${rm_name}"
	if [[ -v "$var" ]]; then	## Check for cached global variable.
		## Found variable-- use it.
		echo "${!var}"
		return
	fi
	## No cached variable. Look for entry in array.
	while read -r entry; do
		if [[ "$entry" == "$rm_name" ]]; then
			## Cache to global variable.
			declare -g "${var}"="${rm_enum[$entry]}"
			echo "${!var}"
			return
		fi
	done < <(get_preferred_labels "${!rm_enum}")
	echo "No entry for \"$rm_name\" in \"${!rm_enum}\" array." >&2
	terminate

}


#
## UUID-related utility functions:
#

function is_string_uuid() {
	if [[ $1 =~ ^[[:alnum:]]{8}-([[:alnum:]]{4}-){3}[[:alnum:]]{12}$ ]]; then
		return 0	## True.
	else
		return 1	## False.
	fi
}

function gen_uuid() {
	## I am not yet sure how Remarkable's UUID are generated.
	## Checking for uniqueness is probably not useful, but I'm doing it anyway to be safe.
	local prospective_uuid
	if [[ ! -v 'existing_uuids[@]' ]]; then
		## Cache to global variable in case of subsequent calls to this function.
		declare -a -g existing_uuids=()
		readarray -d $'\0' existing_uuids < <(find "$cache" -type f -name "*.$(get_rm_enum 'FileExt' 'metadata')" -print0)
	fi
	while prospective_uuid="$(uuidgen)" ; do
		## assert(is_string_uuid "$prospective_uuid")
		## No (non-assert) check for is_string_uuid, since caller logic may require it anyway.

		## Check pre-existing UUID array to ensure no conflict with the one we generated.
		for uuid in "${existing_uuids[@]}"; do
			if [[ "$uuid" == "$prospective_uuid" ]]; then
				## Generate new UUID and restart array scan.
				continue 2
			fi
		done
		## UUID seems new.
		existing_uuids+=("$prospective_uuid")
		echo "$prospective_uuid"
		return 0
	done
	echo 'Failed to generate new UUID.' >&2
	terminate
}

function parse_uuid_from_file_name() {
	local ret
	## Remove any preceeding path, up through the right-most forward slash.
	ret="${1##*/}"
	## Remove any trailing file extension, starting from the left-most period.
	ret="${ret%%.*}"
	if is_string_uuid "$ret"; then
		echo "$ret"
	else
		terminate
	fi
}

function get_uuid_by_name() {
	local target_name="$1"
	if [[ -z "$target_name" ]]; then return 0; fi	## Print no output (empty string).
	for f in "$cache"/*".$(get_rm_enum 'FileExt' 'metadata')" ; do
		if [[ "$(jq -r '.visibleName' "$f")" == "$target_name" ]]; then
			## Print output.
			parse_uuid_from_file_name "$f"
			return 0
		fi
	done
	return 1
}

function accept_uuid_or_name() {
	if is_string_uuid "$1"; then
		uuid="$1"
		## Currently assumed to exist and be a directory/folder type object!
	else
		uuid="$(get_uuid_by_name "$1" "$cache")"
		## Empty string is valid-- represents document root ($XochitlDir).
	fi
	echo "$uuid"
}


#
## Output/formatting utility functions:
#

function get_indent_str() {
	local -n ret="$1"
	local -i indent_ct="$2"
	local indent_char="${3-	}"	## Default to tab character.
	for (( i=0; i != $indent_ct; i++ )); do
		ret+='\t'
	done
}

function print_with_indent() {
	local -i indent_ct="$1"
	shift
	## All proceeding arguments are printed as messages with that indent level.
	local buff=
	get_indent_str 'buff' "$indent_ct"
	for msg in "$@"; do
		echo -e "$buff$msg"
	done
}

function get_preferred_labels() {	## Print keys from an associative or values from an indexed array.
	## Indirect access to associative array keys seems impossible as of version 5.3.9.
	## `test/[[ -v ...` no longer works on associative arrays since version 5.2 (unless you enable 5.1 compatibility).
	case "${!1@a}" in
		A)
			while read -r key ; do
				echo "$key"
			done < <(eval printf "\"%s\n\"" "\${!$1[@]}")
			;;
		a)
			local -n arr="$1"
			for val in "${arr[@]}" ; do
				echo "$val"
			done
			;;
		*)
			echo "Invalid data type or empty array: \"$1\"" >&2
			terminate
	esac
}


#
## Filesystem utility functions:
#

function add_metadata_file() {	## Create metadata file in cache.
	## This function assumes caller has validated its arguments.
	local fs_dir="$1"	## Support Xochitl sub-directory format.
	local metadata_type="$(get_rm_enum 'ObjectType' "$2")"
	local visible_name="$3"
	local parent_uuid="$4"
	local uuid="$5"	## Unless "$metadata_type" == "${RmObjectType[folder]}".

	if [[ "$metadata_type" == "$(get_rm_enum 'ObjectType' 'folder')" ]]; then
		## assert(!uuid)
		uuid="$(gen_uuid)"
	fi
	if ! is_string_uuid "$uuid"; then
		echo "Invalid UUID: \"$uuid\""
		terminate
	fi

	local new_file_name="$uuid.$(get_rm_enum 'FileExt' 'metadata')"
	local ts="$(date '+%s')000"	## Append empty milisecond precision to epoch.
	## I am not sure whether these are all necessary.
	## The order probably does not matter and will likely be changed by Xochitl anyway.
	cat <<- EOF >> "$fs_dir/$new_file_name"
		{
			"visibleName": "$visible_name",
			"parent": "$parent_uuid",
			"lastModified": "$ts",
			"createdTime": "$ts",
			"new": false,
			"source": "",
			"modified": false,
			"metadatamodified": false,
			"deleted": false,
			"pinned": false,
			"version": 0,
			"type": "$metadata_type"
		}
	EOF
}



#
##
### Sub-operation handler functions:
##
#


function pull_cache() {	## Pull remote device to local cache.
	if (($#)) && [[ "$1" == 'diff' ]]; then
		echo -e 'Format is described in the rsync manual. See "--itemize-changes".\n'
		SyncParams+=("${DiffSyncParams[@]}")
	fi
	## Copy contents of remote directory, not the directory including its contents.
	rsync "${SyncParams[@]}" "$host:$XochitlDir/" "$cache"
}

function push_cache() {	## Push local cache to remote device.
	if (($#)) && [[ "$1" == 'diff' ]]; then
		echo -e 'Format is described in the rsync manual. See "--itemize-changes".\n'
		rsync "${SyncParams[@]}" "${DiffSyncParams[@]}" "$cache/" "$host:$XochitlDir" || return 1
	else
		ssh "$host" systemctl stop xochitl || {
			echo 'Failed to stop remote device service: xochitl' >&2
			terminate
		}
		rsync "${SyncParams[@]}" "$cache/" "$host:$XochitlDir" || return 1
		ssh "$host" systemctl start xochitl || {
			echo 'Failed to start remote device service: xochitl' >&2
			terminate
		}
	fi
}

function diff_cache() {	## Compare local cache to remote device.
	## Strip at most one trailing forward slash from the paths, if present.
	## This is necessary because we append a slash during the path truncation.
	local cache="${cache/%\/}"
	local xochitl_dir="${XochitlDir/%\/}"
	## Sanitise strings for bash (@E) and left side of sed substitution expression.
	## https://unix.stackexchange.com/questions/129059/how-to-ensure-that-string-interpolated-into-sed-substitution-escapes-all-metac/129063#129063
	local sanitised_cache=$(sed 's:[][\\/.^$*]:\\&:g' <<< "${cache@E}")
	local sanitised_xochitl_dir=$(sed 's:[][\\/.^$*]:\\&:g' <<< "${xochitl_dir@E}")
	## The strings above are used to trim file paths to target directories.
	## If "cache" has a parent directory with the same name, truncation may end there.
	#
	## Sed is also used to suppress lines for unchanged items and to cut out checksum strings.
	diff --width="$(tput cols)" --suppress-common-lines \
		--old-line-format='	%l	<++-->	.
' --new-line-format='	.	<--++>	%l
' --unchanged-line-format='	.	.	.
' \
		<(find "$cache" -type f -exec md5sum {} + | sort -k 2 | sed "s/ .*${sanitised_cache}\// /") \
		<(ssh "$host" "find \"$xochitl_dir\" -type f -exec md5sum {} + | sort -k 2 | sed 's/ .*${sanitised_xochitl_dir}\// /'") \
		| sed -E '/^[[:space:].]*$/d; s/((^|>)\s*)[[[:lower:][:digit:]]+ +/\1/' \
		| column -t --output-separator='		' \
			-C name="Local cache",right \
			-C name="Difference" \
			-C name="Remarkable device",right
}


#
##
### Primary operation handler functions:
##
#

function run_cache() {	## Operations relating the local cache and remote device.
	validate_cache "$cache"
	validate_host
	local -A Operations=(
		[push]='push_cache'
		[pull]='pull_cache'
		[diff]='diff_cache'
	)
	if [[ -v '1' ]]; then
		if [[ -n "$1" && -v "Operations[${1,,}]" ]]; then
			local cmd="${Operations[${1,,}]}"
			if is_function_defined "$cmd"; then
				## Handle default false parameters that disable default behaviour.
				if ! get_param 'only_add' || get_param 'no_delete'; then
					## Enable deletion of extraneous receiver-side things.
					## This does not include unsupported files (see below).
					SyncParams+=('--delete')
				fi >/dev/null
				if ! get_param 'unsupported_files' >/dev/null; then
					## Direct rsync to...
					## Ignore unsupported file types.
					for ext in "${RmFileExt[@]}" "${RmSupportedImportFileExt[@]}"; do
						SyncParams+=("-f+ *.$ext")
					done
					SyncParams+=('-fH,! */')
					## Delete empty directories.
					## These likely only contained unsupported file types.
					SyncParams+=('--prune-empty-dirs')
				fi

				shift
				"$cmd" "$@"
				return "$?"
			fi
		fi
		echo "Invalid cache operation: \"$1\"" >&2
	fi
	local -n ptr='Operations'
	print_options "${!ptr}" 'Operations'
	terminate
}

function run_list_directory() {	## Enumerate contents of a Remarkable folder object (in the cache).
	local parent="${1:-/}"
		## Initially name; uuid for recursive calls.
		## Default to document root ("/" --> "").
	local -i recursive_depth_remaining="${2:--1}"
		## Default to 0 (no recursion).
		## Negative for infinite (unless decrement overflows).
		## This may or may not have fork bomb potential.
	local -i initial_recursion_depth_limit="${3:-$recursive_depth_remaining}"
	validate_string_not_empty "$parent"
	validate_cache "$cache"

	local parent_name
	local parent_uuid
	local parent_metadata_file
	if (( recursive_depth_remaining == initial_recursion_depth_limit )); then
		## This is not a recursive iteration.
		parent_name="$parent"
		if [[ "$parent_name" == '/' ]]; then
			parent_name=''
			parent_uuid=
		else
			parent_uuid="$(get_uuid_by_name "$parent_name" "$cache")"
			validate_string_not_empty "$parent_uuid" "Failed to locate UUID for object named \"$parent_name\"."
		fi
	else
		## This is a recursive iteration.
		parent_uuid="$(parse_uuid_from_file_name "$parent")"
		parent_name=
	fi

	local current_recursion_depth=$((initial_recursion_depth_limit - recursive_depth_remaining))
	local indent_str=	## Indent with tabs for each level of recursion.
	get_indent_str 'indent_str' "$current_recursion_depth"
	for f in "$cache"/*".$(get_rm_enum 'FileExt' 'metadata')" ; do
		if [[ "$(jq -r '.parent' "$f")" == "$parent_uuid" ]]; then
			## Print name registered in metadata (not the UUID file name).
			case $(jq -r '.type' "$f") in
				$(get_rm_enum 'ObjectType' 'folder'))
					echo -e "$indent_str$(jq -j '.visibleName' "$f")/"	## Append '/' after folder names.
					## Handle recursion if enabled.
					if (( $recursive_depth_remaining != 0 )); then
						run_list_directory "$f" $((recursive_depth_remaining - 1)) "$initial_recursion_depth_limit"
					fi
					;;
				$(get_rm_enum 'ObjectType' 'document'))
					echo -e "$indent_str$(jq -j '.visibleName' "$f")"
					local document_uuid="$(parse_uuid_from_file_name "$f")"
					## Indent information about and files subsidiary to this object.
					local sub_document_depth=$((current_recursion_depth + 1))
					## Print UUID associated with this object.
					print_with_indent "$sub_document_depth" "UUID: $document_uuid"
					## Print type of all files associated with this object.
					for ff in "$cache/$document_uuid."* ; do
						print_with_indent "$sub_document_depth" ".${ff##*.}"
					done
					if [[ -d "$cache/$document_uuid" ]]; then
						print_with_indent "$sub_document_depth" "/"
						for ff in $cache/$document_uuid/* ; do
							print_with_indent $((sub_document_depth + 1)) "${ff##*/}"
						done
					fi
					;;
				## Others are ignored.
			esac
		fi
	done
}

function run_delete() {	## Delete a Remarkable object's file(s) (from the cache).
	local target="$1"
	validate_string_not_empty "$target" "Missing parameter expected: target object"
	validate_cache "$cache"

	if ! is_string_uuid "$target"; then
		local target_name="$target"
		## `... || true` is hack around `set -o errexit`.
		target="$(get_uuid_by_name "$target" "$cache" || true)"
		validate_string_not_empty "$target" \
			"Failed to find UUID associated with target name: \"$target_name\""
	fi
	if ! rm -rv "$cache/$target"* ; then terminate; fi
}

function run_mkdir() {	## Make a Remarkable folder object (not filesystem directory) (in the cache).
	local dir_name="$1"
	local parent_uuid="$(accept_uuid_or_name "$cache" "$2")"
	validate_string_not_empty "$dir_name"
	validate_cache "$cache"

	add_metadata_file "$cache" 'folder' "$dir_name" "$parent_uuid"
}

function run_add_file() {	## Copy a supported file type (from anywhere) as/into a new Remarkable object (in the cache).
	local file_src="$1"
	local parent_uuid="$(accept_uuid_or_name "$cache" "$2")"
	if [[ ! -f "$file_src" ]]; then
		echo "Source file does not exist: \"$file_src\"" >&2
		terminate
	fi
	validate_cache "$cache"

	local uuid="$(gen_uuid)"
	local file_ext="${file_src##*.}"
	local uuid_file_name=
	for ext in ${RmSupportedImportFileExt[@]}; do
		if [[ "$file_ext" == "$ext" ]]; then
			uuid_file_name="$uuid.$file_ext"
			break
		fi
	done
	if [[ -z "$uuid_file_name" ]]; then
		echo "File extension is not supported: \"$file_ext\"" >&2
		echo "Supported extensions:"
		for ext in ${RmSupportedImportFileExt[@]}; do
			echo -e "\t$ext"
		done
		terminate
	fi

	local visible_name="${file_src##*/}"
	visible_name="${visible_name%%.*}"
	validate_string_not_empty "$visible_name"

	## Add the file.
	cp --update=none-fail "$file_src" "$cache/$uuid_file_name" || terminate

	## Add a corresponding metadata file.
	add_metadata_file "$cache" 'document' "$visible_name" "$parent_uuid" "$uuid"

	## Add .content file. I have no idea why this is necessary, but it is.
	if [[ -e "$cache/$uuid.$(get_rm_enum 'FileExt' 'content')" ]]; then
		echo 'Detected pre-existing .content file while adding new document. It will not be over-written.' >&2
	else
		echo '{}' > "$cache/$uuid.$(get_rm_enum 'FileExt' 'content')"
	fi
}

function run_rename() {	## Change the visible name associated with a Remarkable object (in the cache).
	local target="$(accept_uuid_or_name "$cache" "$1")"
	local new_name="$2"
	validate_string_not_empty "$target"
	validate_cache "$cache"

	local target_file="$cache/$target.$(get_rm_enum 'FileExt' 'metadata')"
	## Only over-write on successful jq return status.
	jq ".visibleName = \"$new_name\"" "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
}

function run_move() {	## Change the parent directory associated with a Remarkable object (in the cache).
	local target="$(accept_uuid_or_name "$cache" "$1")"
	local new_parent="$(accept_uuid_or_name "$cache" "$2")"
	validate_string_not_empty "$target"
	validate_cache "$cache"

	local target_file="$cache/$target.$(get_rm_enum 'FileExt' 'metadata')"
	## Only over-write on successful jq return status.
	jq ".parent = \"$new_parent\"" "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
}


#
## Meta-operations:
#

function print_options() {
	local -n valid="$1"
	local subject="${2,,}"
	## assert("${subject:-1:1}" == "s")

	echo "${subject@u} available at this scope:"
	while read -r item; do
		echo -e "\t$item"
	done < <(get_preferred_labels "${!valid}")
}

function run_print_help() {
	echo -e "\nSYNTAX: \`${0##*/} [Flag]... <Operation>\`\n" \
		" Operation: \`<name> [(scoped) Flag]... [(sub-)Operation]\`\n" \
		" Flag: \`-[-]<parameter>[=<value>]\`\n"
	cat <<- EOF


		It should be safe to run operations with missing parameters.
		When one is missing, you will be told what the next parameter field should be.
		Many functions define variables of questionable utility as an attempt at documentation.

		Only \`cache\` operations interact with the remote device.
		The only operation that attempts to modify the remote device is \`cache push\`.
		No effort is made to avoid incidental modification, like updating file access timestamps.
		Running \`cache push\` will, upon completion, restart the remote device's xochitl service.

		Synchronisation (\`cache push\`/\`cache pull\`) is performed using rsync.
		These operations will delete anything on the receiving side that is not on the sending side!
		Sync behaviour can be adjusted by editing the "SyncParams" variable at the top of this script.

		Almost all operations require the "cache" parameter to have been set.
		\`Cache\` operations also require the "host" parameter, corresponding to your S.S.H. host.


	EOF
	print_options "${!valid_params}" 'Parameters'
	echo
	print_options "${!valid_ops}" 'Operations'
	echo
}


#
## Initialisation operations:
#

function parse_config_file() {
	## Multiple delim characters should be interpreted independently.
	local ConfigKeyValDelim='='
	local LineCommentDelim='#'
	while read -r line; do
		## Whitespace leading or trailing line has been stripped.
		## Skip empty lines and comment lines.
		case ${line:0:1} in
			''|["$LineCommentDelim"]) continue ;;
		esac
		## Split line into key/value pair.
		IFS="$ConfigKeyValDelim" read -r key val <<< "$line" || return 1
		## Strip whitespace that was surrounding ConfigKeyValDelim.
		read -r key <<< "$key"
		read -r val <<< "$val"
		## If value begins with tilde slash, let shell expand it.
		if [[ "${val:0:2}" == '~/' ]]; then
			val=~/"${val:2}"
		fi
		parse_param "$key" "$val" || return 1
	done < "$config_file"
}



#
##
### Main:
##
#
{
	set -o errexit	## Terminate on first error.
	set -o nounset
	shopt -s nullglob	## Ignore globs/wildcards that match nothing.


	## Parameters are declared as global variables (if not already in use).
	## String values provided at run-time are assigned to their respective variable.
	## If no value is provided at run-time:
	## 	The value "1" (representing true/on) is assigned.
	## 	If a corresponding handler function is defined, it is run positionally.
	## 		Effects apply only for proceeding parameters and operations.
	declare FlagPrefixSymbol='-'
	declare FlagKeyValDelim='='

	##   Key: Argument string to identify parameter.
	## Value: Name of handler function OR script-global variable to assign.
	declare -A MainParams=(	## Declared as script-global variables (if not already in use).
		[cache]='cache'                          ## String: Path to cache directory.
		[host]='host'                            ## String: S.S.H. host value for Remarkable device.
		[config]='config_file'                   ## String: Path to optional config file.
		[no-add]='no_add'                        ##   Bool: Only update or delete existing things.
		[no-delete]='no_delete'                  ##   Bool: Do not delete anything.
		[only-add]='only_add'                    ##   Bool: Do not delete or over-write anything.
		[only-delete]='only_delete'              ##   Bool: Do not add or over-write anything.
		[unsupported-files]='unsupported_files'  ##   Bool: Remove unsupported files and empty directories.
		[debug]='debug'                          ##   Bool: Enable bash debug output.
		[script]='source_script'                 ## String: Path to script that should be sourced.
	)
	for f in "${MainParams[@]}"; do
		## "-v" condition supports shell with `set -u`/`set -o nounset` enabled.
		if [[ -v "$f" && -n "${!f}" ]]; then
			echo "Hard-coded parameter variable already in use: \"$f\"" >&2
			terminate
		fi
	done
	function handle_bool_param_debug() {	## Enable mode for parameter: 'debug'
		set -o xtrace
	}
	function handle_bool_param_only_add() {
		if ((only_add)); then
			echo 'Incompatible sync parameters were specified.' >&2
			echo -e \
				'\tno-add\n' \
				'\tonly-add\n'
			terminate
		fi
		SyncParams+=('--ignore-existing')
		## Does this also delete receiver-side files not on the sender?
	}
	function handle_bool_param_no_add() {
		if ((only_add)); then
			echo 'Incompatible sync parameters were specified.' >&2
			echo -e \
				'\tonly-add\n' \
				'\tno-add\n'
			terminate
		fi
		SyncParams+=('--existing')
	}
	function handle_bool_param_only_delete() {
		if ((only_add)); then
			echo 'Incompatible sync parameters were specified.' >&2
			echo -e \
				'\tonly-add\n' \
				'\tonly-delete\n'
			terminate
		fi
		SyncParams+=(
			'--existing'
			'--ignore-existing'
		)
	}
	function handle_param_source_script() {
		if ((${#@} <= 0)); then
			echo 'Can not source unspecified script.' >&2
			terminate
		fi
		local file_to_source="$1"
		if [[ ! -f "$file_to_source" ]]; then
			echo "Requested file to source does not exist: \"$file_to_source\"" >&2
			terminate
		fi
		if ! source "$file_to_source"; then
			echo "Failed to source requested file: \"$file_to_source\"" >&2
			terminate
		fi
	}

	function parse_param() {
		local key="$1"
		local val="$2"

		## Validate that specified key is known/handled (was set/assigned/initialised).
		local -n param
		for p in "${!valid_params[@]}"; do
			if [[ "$p" == "$key" ]]; then
				param="valid_params[$key]"
				break
			fi
		done
		if [[ ! -R 'param' ]]; then
			echo "Invalid parameter: \"$key\"" >&2
			terminate
		fi

		## Check whether a handler function matching the parameter name exists.
		if is_function_defined "handle_param_$param"; then
			## Run it immediately with the supplied value as its first argument.
			## Terminate on non-zero return status from that function.
			"handle_param_$param" "$val" || terminate
			## No additional actions are taken for these parameters.
			return
		fi

		## The remaining parameter types are boolean and string.
		## Both are assigned to global variables.

		## Protect against namespace conflicts with caller's environment.
		if [[ -v "$param" ]]; then
			echo "Value already assigned to parameter variable: \"$param\"." >&2
			echo 'This could be a result of duplicate specification or namespace conflict.'
			terminate
		fi

		## Accept flags without a specified val(ue) as boolean toggle switches.
		if [[ -z "$val" ]]; then
			declare -g -i "$param"=1	## 1 == true. Not declared as integer type.
			## If there a handler function is defined for this flag, run it now.
			if is_function_defined "handle_bool_param_$param"; then
				"handle_bool_param_$param"
			fi
			return
		fi

		declare -g "$param"="$val" || {
			echo "Failed to assign value to parameter: \"$param\"" >&2
			echo -e "\tValue was: \"$val\""
			terminate
		}
	}
	function parse_flag() {
		## $1: Flag string, including prefix, delimiter, and value if applicable.
		local key
		local val=

		## Count length of flag prefix.
		local -i i=0
		while [[ "${1:$i:1}" == "$FlagPrefixSymbol" ]]; do
			i+=1
			if (( $i > 2 )); then
				echo "Invalid prefix ($i+) for supposed flag: \"$1\""
				terminate
			fi
		done
		## assert(i>0)

		IFS=\= read -r key val <<< "${1:$i}" || {
			echo "Failed to parse flag parameter: \"$1\"" >&2
			terminate
		}

		parse_param "$key" "$val"
	}



	## Map C.L.I. arguments to operational run modes.
	## 	Key: Argument string to invoke call.
	## 	Val: Handler function name.
	declare -A PrimaryOperations=(
		[cache]='run_cache'
		[list]='run_list_directory'
		[delete]='run_delete'
		[mkdir]='run_mkdir'
		[add]='run_add_file'
		[rename]='run_rename'
		[move]='run_move'
		[help]='run_print_help'
	)

	declare -n -g valid_ops='PrimaryOperations'
	declare -n -g valid_params='MainParams'
	declare -n run_op

	## Parse positional, C.L.I. arguments.
	for arg in "$@"; do
		shift
		if [[ "${arg:0:1}" == "-" ]]; then
			## Argument is a flag (prefixed with one or more hyphens).
			## assert [[ ! -R 'run_op' ]]
			parse_flag "$arg"	## Terminates on failure.
		else
			## Argument is not a flag (prefixed with one or more hyphens).
			arg="${arg,,}"	## No need for case sensitivity in command namespace.
			if
				## First condition supports shell with `set -u`/`set -o nounset` enabled.
				[[ -v "valid_ops["$arg"]" ]] \
				&& is_function_defined "${valid_ops["$arg"]}"
			then
				## assert [[ ! -R 'run_op' ]]
				run_op="valid_ops["$arg"]"
				## Only accept one operation per invocation of this script.
				break
			else
				echo "Invalid operation: \"$arg\"" >&2
				print_options "${!valid_ops}" 'Operations'
				terminate
			fi
		fi
	done

	## Parse config file after parameters, so path can be specified via C.L.I.
	if [[ -v 'config_file' ]]; then
		## Config file path was specified via C.L.I.
		## Abort script if the file can not be found.

		## Hack around Bash mistaking flags for variable assignment.
		## https://stackoverflow.com/questions/51713759/bash-tilde-not-expanding-in-certain-arguments-such-as-home-dir/51713895#51713895
		if [[ "${config_file:0:2}" == '~/' ]]; then
			config_file=~/"${config_file:2}"
		fi

		if [[ ! -f "$config_file" ]]; then
			echo "Specified config file does not exist: \"$config_file\""
			exit 1
		fi
		parse_config_file "$config_file" || exit
	else
		## Config file path was not specified via C.L.I.
		## Attempt to load config from default file path.
		if [[ -v 'XDG_CONFIG_HOME' && -n "$XDG_CONFIG_HOME" ]]; then
			## assert [[ "${XDG_CONFIG_HOME:-1:1}" != '/' ]]
			config_file="$XDG_CONFIG_HOME/remarkable-ssh.conf"
		else
			## Unquoted for tilde expansion.
			config_file=~/'.config/remarkable-ssh.conf'
		fi
		if [[ -f "$config_file" ]]; then
			parse_config_file "$config_file" || exit
		fi
	fi

	if [[ -R 'run_op' ]]; then
		## Run the specified operation.
		"$run_op" "$@"
	else
		## No valid or invalid run_op was specified (only flag parameters or nothing).
		run_print_help
	fi
}
