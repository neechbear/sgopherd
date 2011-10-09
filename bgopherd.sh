#!/bin/bash

# ------------------------------------------------------------------
# "THE PIZZA-WARE LICENSE" (Revision 42):
# Peter Hofmann <pcode@uninformativ.de> wrote this file. As long as you
# retain this notice you can do whatever you want with this stuff. If
# we meet some day, and you think this stuff is worth it, you can buy
# me a pizza in return.
# ------------------------------------------------------------------


# --- Find and load config.
config=/etc/bgopherd.conf

while getopts c: name; do
	case $name in
		c) config="$OPTARG" ;;
	esac
done

. "$config" || { echo "Unable to load config file." >&2; exit 1; }

# --- Library functions.
rel2abs()
{
	# Convert a relative path into an absolute one. Do NOT use readlink
	# because that would break support for symbolic links which point
	# outside the document root. Instead, temporarily change into the
	# directory, then print the current directory. This way, the kernel
	# resolves relativ paths.

	[[ -d "$1" ]] && { (cd -- "$1"; echo "$PWD"); return; }
	[[ -f "$1" ]] && { (cd -- "${1%/*}"; echo "$PWD/${1##*/}"); return; }
}

dirEmpty()
{
	# Test if the directory $1 is empty. If there's at least one
	# non-hidden file, then the new $1 will contain it's name. If
	# there's NO file, then $1 will contain "$1/*" which does not exist.

	set -- "$1"/*
	[[ ! -e "$1" ]]
}

parseIndex()
{
	# Parse an index file. The syntax is similar to the one of geomyidae
	# (another gopher server). Lines beginning with a bracket denote a
	# menu item, all other lines are informational text.
	#
	# Substitute $MYHOST and $MYPORT with the server's settings. Also
	# turn relative paths into absolute ones: Paths that do not begin
	# with a "/" are relative to $rel.
	#
	# Read from STDIN if $@ is empty.

	rel=$1
	shift

	sed \
		-e '/^\[/! { s/.*/i&\t-\t-\t0/ }' \
		-e '/^\[/ { s/\$MYHOST/'"$servername"'/g }' \
		-e '/^\[/ { s/\$MYPORT/'"$serverport"'/g }' \
		-e '/^\[/ { s,^\(...[^|]\+|\)\([^/]\),\1'"$rel"'/\2, }' \
		-e '/^\[/ { s/\[//; s/^\(.\)|/\1/; s/\]//; s/|/\t/g }' \
		-e 's/$/\r/' \
		"$@"
}

isCGI()
{
	# Any executable file with a name ending in ".cgi" is meant to be a
	# script. It'll be executed when requested by a client, its output
	# is shown without further post-processing.

	[[ -x "$1" ]] && [[ "${1##*.}" == "cgi" ]]
}

isDCGI()
{
	# See isCGI(). However, the output of a DCGI file is piped into
	# parseIndex().

	[[ -x "$1" ]] && [[ "${1##*.}" == "dcgi" ]]
}

sendListing()
{
	# Auto-create a menu, try to guess file types.

	dirEmpty "$1" && return

	for i in "$1"/*; do
		if [[ -d "$i" ]]; then
			itype=1
		else
			# The default type for files is 0, that is plain text. If
			# any of the following conditions matches, then $itype will
			# get overwritten.
			itype=0
			if isDCGI "$i"; then
				# As DCGI files are always piped into parseIndex(), they
				# must be menus. However, if their name begins with
				# "query_", then this script can receive search queries.
				itype=1
				bname=${i##*/}
				bname=${bname,,}
				if [[ "${bname:0:6}" == "query_" ]]; then
					itype=7
				fi
			else
				# Try to deduce file types from file name extensions.
				ext=${i##*.}
				if [[ -n "$ext" ]]; then
					case "${ext,,}" in
						html|htm|xhtm|xhtml) itype=h ;;
						jpeg|jpg|png|tif|tiff|bmp|svg) itype=I ;;
						exe|bin|iso|img|gz|xz|tar|tgz) itype=9 ;;
						gif) itype=g ;;
					esac
				fi
			fi
		fi

		# Print this menu item, show the base name of $i.
		printf "%s%s\t%s\t%s\t%d\r\n" \
			$itype \
			"${i##*/}" \
			"${i:${#docroot}}" \
			"$servername" \
			"$serverport"
	done
}

run()
(
	# Run a script. The working directory will be the script's location.
	# Note the parentheses around this function: They'll start a
	# subshell (and break syntax highlighting of Vim).
	cd -- "${1%/*}"
	"$@"
)

# --- Process a request.
# Read a line from STDIN. First, remove any CRs and extract selector and
# search query (if any).
read -r request
request=${request//$'\r'/}
selector=${request%$'\t'*}
search=${request#*$'\t'}

# Prefix the selector with the path of the document root. Then convert
# this path into an absolute one. If the result is still a path below
# $docroot, then it's okay to proceed. Hence, this routine makes it
# impossible to request something like "/..".
absreq=$(rel2abs "$docroot$selector")
if [[ "${absreq:0:${#docroot}}" == "$docroot" ]]; then
	# In directories, try to find a file called INDEX which may be a
	# manually created menu. An INDEX.dcgi script may be used to
	# dynamically create a menu. Otherwise, we'll simply show the
	# directories contents.
	if [[ -d "$absreq" ]]; then
		if [[ -f "$absreq"/INDEX ]]; then
			parseIndex "${absreq:${#docroot}}" "$absreq"/INDEX
		elif isDCGI "$absreq"/INDEX.dcgi; then
			run "$absreq"/INDEX.dcgi | parseIndex "${absreq:${#docroot}}"
		else
			sendListing "$absreq"
		fi
	elif isCGI "$absreq"; then
		run "$absreq" "$search"
	elif isDCGI "$absreq"; then
		# If a DCGI script outputs a relative path, then this path is
		# meant to be relative to the scripts location.
		rel="${absreq:${#docroot}}"
		rel="${rel%/*}"
		run "$absreq" "$search" | parseIndex "$rel"
	else
		# This is a regular file. Just show it.
		cat "$absreq"
	fi
else
	printf "%d%s\t%s\t%s\t%d\r\n" \
		3 "\`$request' invalid." "Error" "Error" 0
fi
