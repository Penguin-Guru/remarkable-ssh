#!/bin/bash


function dev_test_fn() {	## Directly run a specific function.
	if [[ ! ( -v '1' && -n "$1" ) ]]; then
		echo 'No target function name was provided to `test_fn`.' >&2
		terminate
	fi
	local fn="$1"
	if is_function_defined "$fn"; then
		shift
		"$fn" "$@"
	else
		echo "No definition for specified function: \"$fn\""
		terminate
	fi
}

function dev_list_nop_fn() {	## List functions not included in the PrimaryOperations array.
	local -a nop_fns=()
	while read -r line; do
		## Buffer only the last (right-most) whitespace delimited string.
		buff="${line##* }"
		for op in "${PrimaryOperations[@]}"; do
			if [[ "$op" == "$buff" ]]; then
				## Skip this function name.
				continue 2
			fi
		done
		## Buffered function name is not in PrimaryOperations array.
		nop_fns+=("$buff")
	done < <(declare -F)

	if (( ${#nop_fns} )); then
		echo 'Defined functions not declared in PrimaryOperations array:'
		for fn in "${nop_fns[@]}"; do
			echo -e "\t$fn"
		done
	else
		echo 'No functions defined other than those in the PrimaryOperations array.'
	fi
}



## Append functions starting with "dev_" to array of valid operations.
## Underscores in function names are translated to hyphens for invocation.
while read -r fn; do
	PrimaryOperations+=(["${fn//_/-}"]="dev_$fn")
done < <(compgen -A function -X '!dev_*' | cut -c 5-)	## 5=sizeof("dev_")

