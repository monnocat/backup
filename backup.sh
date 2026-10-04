#!/usr/bin/env nix-shell
#! nix-shell -i bash --pure
#! nix-shell -p bash jq zip

# Print to stderr
# Does nothing if all inputs are empty
log() {
    if [[ -n "$*" ]]; then
        echo "$@" >&2
    fi
}

ctrl_c() {
    log "Exiting"
    if [[ -n $start && -n $temp_output_file ]]; then
        file="$start/$temp_output_file"
        log "Removing $file"
        rm "$file"
    fi
}

set -Eeo pipefail
stty -echoctl   # hide ^C
trap ctrl_c INT # trap Ctrl+C

# parse args
while [[ $# -gt 0 ]]; do
    case $1 in
    -c | --config)
        config_file=$2
        shift # past argument
        shift # past value
        ;;
    -o | --output)
        output_file=$2
        shift # past argument
        shift # past value
        ;;
    -h | --help)
        log "./backup.sh [-c config] [-o output]
  -c config: Optional. A config file. Defaults to config.json.
  -o output: Optional. An output file. Defaults to backup-YYYY-MM-DD-XXXXX.tar.gz. Supported extensions are tar.gz and zip."
        exit 0
        ;;
    -*)
        log "Unknown option: got $1, expected one of [-c, --config, -o, --output]"
        exit 1
        ;;
    *)
        if [[ -z $config_file ]]; then
            config_file=$1
        elif [[ -z $output_file ]]; then
            output_file=$1
        fi
        shift # past argument
        ;;
    esac
done

# default config file
if [[ -z $config_file ]]; then
    config_file='config.json'
    log "No config file provided, using $config_file"
fi
config_content=$(cat "$config_file")

# parse/default output file
if [[ -z $output_file ]]; then
    output_filename="backup-$(date "+%Y-%m-%d")"
    output_format='tar.gz'
    log "No output file provided, using $output_filename-XXXXX.$output_format"
else
    case $output_file in
    *.tar.gz)
        output_filename="${output_file%".tar.gz"}"
        output_format='tar.gz'
        ;;
    *.zip)
        output_filename="${output_file%".zip"}"
        output_format='zip'
        ;;
    *)
        log "Unsupported output format: got ${output_file#*.}, expected one of [tar.gz, zip]"
        exit 1
        ;;
    esac
fi

temp_output_file=".$output_filename.$output_format"

# List all files except . and .., without the starting ./
# $1: max depth
# returns: list of paths
list_files() {
    find . -maxdepth "$1" ! -name . -printf '%P\n'
}

# Shorthand for jq -c
jq() {
    command jq -c "$@"
}

# Get the type of a JSON expression
# $1: any JSON expression
# $2?: expression for $1
# returns: one of ["number", "boolean", "array", "object", "null", "string"]
type() {
    jq -r "${2:-.} | type" <<<"$1"
}

# Filters for existing paths
# $1: JSON array of paths
# returns: JSON array of paths
existing_paths() {
    IFS=$'\n'
    paths=$(
        for path in $(jq -r '.[]' <<<"$1"); do
            if [[ -d $path ]]; then
                echo "\"$path\""
            fi
        done
    )
    jq -s <<<"$paths"
}

# Filters for existing items
# $1: JSON array of paths
# returns: JSON array of paths
existing_items() {
    IFS=$'\n'
    items=$(
        for item in $(jq -r '.[]' <<<"$1"); do
            if [[ -e $item ]]; then
                echo "\"$item\""
            fi
        done
    )
    jq -s <<<"$items"
}

# Validate a path
# $1: path
# $2?: expression for $1
validate_path() {
    jq "
        ${2:-.} |
        if contains(\"//\") then
            error(\"Paths can't contain consecutive slashes: \" + .)
        else
            .
        end
    " <<<"$1" >/dev/null
}

# Normalize a JSON array of paths
# $1: JSON array of paths
# returns: JSON array of paths
normalize_paths() {
    validate_path "$1" '.[]'
    jq '[.[] | (split("/") | map(select(length > 0 and . != ".")) | join("/"))]' <<<"$1"
}

# Finds the sum of two JSON arrays
# $1: JSON array
# $2: JSON array
# returns: JSON array
sum() {
    jq -s '.[0] + .[1]' <<<"$1 $2"
}

# Finds the difference between two JSON arrays
# $1: JSON array
# $2: JSON array
# returns: JSON array
difference() {
    jq -s '.[0] - .[1]' <<<"$1 $2"
}

# Finds the intersection between two JSON arrays
# $1: JSON array
# $2: JSON array
# returns: JSON array
intersection() {
    jq -s '.[0] - (.[0] - .[1])' <<<"$1 $2"
}

# Resolve a config to a list of paths
# $1: JSON config
# $2: current path
# returns: list of paths
resolve() {
    # if there are no top items, there is nothing to return
    if [[ -z "$(ls -A .)" ]]; then
        echo '[""]'
        return 0
    fi

    # verify the JSON type of the given config
    config_type=$(type "$1")
    case $config_type in
    # if the config is a string, retrieve the associated template
    "string")
        config=$(jq ".templates.\"$(jq -r '.' <<<"$1")\"" <<<"$config_content")
        ;;
    # if it's an object, use it directly
    "object")
        config=$1
        ;;
    # otherwise it's invalid
    *)
        log "Invalid config type: got $config_type, expected one of [\"string\", \"object\"]"
        return 1
        ;;
    esac

    mode=$(jq -r '.mode' <<<"$config")

    # files in the current directory
    top_items=$(list_files 1 | jq -Rn '[inputs]')

    # all configs
    configs=$(jq '.configs // []' <<<"$config")
    # items that need to be configured
    configs_items=$(jq 'keys' <<<"$configs")
    configs_items=$(existing_paths "$configs_items")

    case $mode in
    all)
        items=$top_items
        ;;
    include)
        include=$(jq '.include // []' <<<"$config")
        include=$(normalize_paths "$include")
        include=$(existing_items "$include")
        #* this is wrong because nested items are allowed
        # items=$(intersection "$top_items" "$include")
        items=$include

        # configure every included path
        configs_items=$(intersection "$configs_items" "$include")
        ;;
    exclude)
        exclude=$(jq '.exclude // []' <<<"$config")
        exclude=$(normalize_paths "$exclude")
        #* unnecessary because they get excluded anyway
        # exclude=$(existing_paths "$exclude")
        items=$(difference "$top_items" "$exclude")

        # configure every but excluded path
        configs_items=$(difference "$configs_items" "$exclude")
        ;;
    *)
        log "Invalid mode: got $mode, expected one of [all, include, exclude]"
        return 1
        ;;
    esac

    # exclude every path that needs to be configured
    items=$(difference "$items" "$configs_items")
    # exclude the backup archive itself
    items=$(jq "map(select(. != \"$temp_output_file\"))" <<<"$items")

    # log the progress
    log "$(jq -r ".[] | \"- $2/\" + ." <<<"$items")"

    configs_items_list=$(jq -r '.[]' <<<"$configs_items")
    if [[ -n "$configs_items_list" ]]; then
        # resolve each config
        while read -r dir; do
            # get the config for this dir
            config=$(jq ".\"$dir\" // .\"*\"" <<<"$configs")

            # resolve the dir
            cd "$dir"
            resolved=$(
                set -Eeuo >/dev/null
                resolve "$config" "$2/$dir"
            )
            cd '-' >/dev/null

            # prepend dir to all results
            resolved=$(jq "[\"$dir/\" + .[]]" <<<"$resolved")
            items=$(sum "$items" "$resolved")
        done <<<"$configs_items_list"
    fi

    echo "$items"
}

start="$(jq -r '.start' <<<"$config_content")"
cd "$start"

log "Adding the following paths:"
items=$(
    set -Eeuo >/dev/null
    resolve "$config_content" "$start"
)

mapfile -t items < <(
    set -Eeuo >/dev/null
    jq -r '.[]' <<<"$items"
)

case "$output_format" in
tar.gz)
    log "Starting tar..."
    tar -czf "$temp_output_file" --exclude "$temp_output_file" "${items[@]}"
    ;;
zip)
    log "Starting zip..."
    zip -r9 "$temp_output_file" -x "$temp_output_file" @ "${items[@]}"
    ;;
esac

hash=$(sha256sum "$temp_output_file" | cut -c1-5)
cd '-' >/dev/null
mv "$start/$temp_output_file" "$output_filename-$hash.$output_format"
