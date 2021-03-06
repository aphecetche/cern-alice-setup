#!/bin/bash

#
# git-split-tools.sh -- by Dario Berzano & Alina Grigoras
#
# A set of utilities to help removing permanently files from a Git
# repository.
#


# a print function with colors, on stderr
function prc() (
  declare -A color
  color=(
    [red]="\033[31m"
    [yellow]="\033[33m"
    [green]="\033[32m"
    [blue]="\033[34m"
    [magenta]="\033[35m"
    [hi]="\033[1m"
  )
  selcol=${color[$1]:=${color[hi]}}
  nocol="\033[m"
  echo -e "${selcol}$2${nocol}" >&2
)

# a print function
function pr() (
  prc hi "$1"
)

# break if something is wrong
function fatal() {
  "$@"
  local rv=$?
  if [[ $rv != 0 ]] ; then
    prc red "this should not happen, aborting:"
    prc red "  $* --> returned $rv"
    exit 10
  fi
}

# update remote branches
function updbr() (
  fatal cd "$GitRootSplit"
  prc yellow 'updating list of remote branches'
  fatal git remote update --prune
)

# list remote branches
function lsbr() (

  # the git plumbing interface (to be used in scripts):
  # https://www.kernel.org/pub/software/scm/git/docs/git.html#_low_level_commands_plumbing

  fatal cd "$GitRootSplit"
  remote="$1"

  prc yellow "listing all available remote branches from remote \"$remote\""

  # produce lines to be either piped in shell, or eval'd
  # the %(var) is correctly escaped
  # this one produces one line per *remote* branch.
  git for-each-ref --shell \
    --format 'echo %(refname)' \
    "refs/remotes/${remote}/" | \
    while read Line ; do
      if [[ $(eval "$Line") =~ /([^/]*)$ ]] ; then
        pr ${BASH_REMATCH[1]}
      else
        prc red "should not happen, aborting: $Line"
        exit 10
      fi
    done

)

# cleans all: reverts all to a pristine state (just cloned)
function cleanall() (

  fatal cd "$GitRootSplit"
  prc yellow "cleaning all"

  # move to detached
  fatal git clean -f -d
  fatal git reset --hard remotes/origin/HEAD
  fatal git checkout $(git rev-parse HEAD)

  # iterates over all refs and deletes them all
  # note: we will restore them with "remote update"
  while read Cmd ; do
    eval "$Cmd"
  done < <( git for-each-ref --shell --format 'fatal git update-ref -d %(refname)' )

  # move to master
  fatal git remote update --prune
  fatal git checkout master
  fatal git clean -f -d
  fatal git reset --hard remotes/origin/HEAD
  fatal git pull

  prc green "repository restored to a pristine and updated state: now it looks like a fresh clone :-)"
  prc blue "tip: use \"gc\" to get rid of dangling commits"

)

# slim a repository
function slimrepo() (

  fatal cd "$GitRootSplit"

  # ask for confirmation
  right_answer='yes, I intend to proceed!'
  prc red "you are about to do something potentially catastrophic:"
  prc red " - all backups Git has made (refs/original) will be deleted"
  prc red " - all remote refs will be deleted (though locally only)"
  prc red "you must confirm this operation by typing: \"${right_answer}\""
  read -p ':> ' given_answer
  fatal [ "$given_answer" == "$right_answer" ]

  prc magenta 'removing backups and all remotes'
  fatal git for-each-ref --format="%(refname)" refs/original/ refs/remotes | xargs -n 1 git update-ref -d

  prc magenta 'expiring all dangling refs'
  fatal git reflog expire --expire=now --all

  prc magenta 'garbage collecting (might take a while)'
  fatal git gc --prune=now

)

# list all files ever written in all remote branches, also the ones not
# currently present in the working directory, also the ones that have
# been deleted
function lsallfiles() (

  # list what changed in revision <rev> (wrt/the previous)
  #   git diff-tree --no-commit-id --name-only -r <rev>
  # if run on every commit, it will produce eventually the full list
  # of files ever written! note that this is much faster than using
  # git ls-files

  # list all commits for a branch (no need to check it out)
  #   git rev-list <branch>

  # list all commits in all remote branches
  #   git rev-list --remotes

  regexp="$1"
  invert_regexp="$2"
  only_root_dir="$3"
  ofile="$4"
  istmpfile="$5"

  prc yellow 'listing all files ever written to Git history in all branches'
  if [[ $regexp != '' ]] ; then
    prc magenta "showing only entries matching extended regexp: $regexp"
    [[ ${invert_regexp} == 1 ]] && prc magenta 'inverting regexp match'
    [[ ${only_root_dir} == 1 ]] && prc magenta 'printing only list of dirs under root'
  fi
  [[ $ofile != '' && $istmpfile != 1 ]] && prc magenta "writing results on stdout and on file: $ofile"

  fatal cd "$GitRootSplit"

  [[ $invert_regexp == 1 ]] && invert_regexp='-v'

  git rev-list --remotes | while read commit ; do
    git diff-tree --no-commit-id --name-only -r $commit | \

      if [[ "$regexp" != '' ]] ; then
        grep $invert_regexp -E "$regexp"
      else
        cat
      fi | \

      if [[ $only_root_dir == 1 ]] ; then
        grep -oE '^([^/]*)/'
      else
        cat
      fi

  done | sort -u | \

    if [[ $ofile != '' ]] ; then
      tee "$ofile"
    else
      cat
    fi

)

# rewrite history by removing files forever
function rewritehist() (

  prc yellow 'rewriting Git history by removing files forever'

  fatal cd "$GitRootSplit"

  ifile="$1"
  if [[ ! -s $ifile ]] ; then
    prc red 'input list is empty, aborting'
    return 1
  fi

  prc magenta "removing the following files (args passed as-is to 'git rm'):"
  ifile_tmp=$(mktemp /tmp/ali-split-list-XXXXX)
  fatal cp "$ifile" "$ifile_tmp"
  while read line ; do
    pr "$line"
  done < <(fatal cat "$ifile_tmp")

  remote="$2"

  # creates one local branch per remote branch: remote branches are
  # taken from the specified remote.
  # note that it does not checkout the branches (i.e. it does not
  # change the current working directory.
  # in order for it to work, we are moving to a "detached head" state
  # and it is better to call this command after "cleanall".
  prc magenta "checking out all branches from remote \"${remote}\""
  fatal git checkout "refs/remotes/${remote}/HEAD"  # detached head
  while read RefBranch ; do
    RefBranch=$(eval "$RefBranch")
    if [[ $RefBranch =~ /([^/]*)$ ]] ; then
      ShortBranch=${BASH_REMATCH[1]}
    else
      prc red "malformed refname: $RefBranch - this should not happen, aborting!"
      exit 10
    fi
    [[ $ShortBranch == 'HEAD' ]] && continue
    prc yellow "branch: $RefBranch -> $ShortBranch"
    fatal git branch --force --track "$ShortBranch" "$RefBranch"
  done < <( git for-each-ref --shell --format 'echo %(refname)' "refs/remotes/${remote}" )

  # have a look at http://git-scm.com/docs/git-filter-branch
  # --index-filter: applies the command to every commit
  # --tag-name-filter cat: applies a "dummy" filter to tags: this is
  #   needed because we want to keep the same tag names on one side,
  #   but we want them to point to the *refactored* commits as well:
  #   if we do not provide any --tag-name-filter, tags will be left
  #   there, pointing to commits that do not exist anymore
  # the final --all is the option passed to 'git rev-list' to retrieve
  # the list of all commits to mangle. in our case, if local==remote,
  # we might as well pass --remotes
  # the complicated index-filter string is derived from here:
  # http://stackoverflow.com/questions/11393817/bash-read-lines-in-file-into-an-array
  # note: empty commits are removed by --prune-empty, but empty merge
  # commits will not!

  # check the affected branches with:
  # git rev-list $( git for-each-ref --format '%(refname)' refs/heads )

  # run while keeping your fingers crossed
  fatal git filter-branch \
    --force \
    --index-filter '( echo ; IFS=$'\''\n\r'\'' GLOBIGNORE="*" ary=($(cat '${ifile_tmp}')) ; git rm -r -f --cached --ignore-unmatch "${ary[@]}" )' \
    --prune-empty \
    --tag-name-filter cat -- $( git for-each-ref --format '%(refname)' refs/heads )

  rm -f ${ifile_tmp}

)

# delete all remote references (branches and tags)
# this command is obviously very dangerous and has an interactive
# confirmation prompt
function delremoterefs() (

  fatal cd "$GitRootSplit"
  remote="$1"

  # ask for confirmation
  right_answer='yes, I intend to proceed!'
  prc red "you are about to do something potentially catastrophic:"
  prc red " - delete all remote branches from the remote named \"${remote}\""
  prc red " - delete all tags from the remote named \"${remote}\""
  prc red "you must confirm this operation by typing: \"${right_answer}\""
  read -p ':> ' given_answer
  fatal [ "$given_answer" == "$right_answer" ]

  # where does HEAD point to?
  ref_head=$( git ls-remote "${remote}" HEAD | awk '{ print $1 }' )
  if [[ ! $ref_head =~ ^([a-fA-F0-9]+)$ ]] ; then
    prc red "cannot get HEAD from \"${remote}\": this should not happen, aborting!"
    exit 10
  fi

  prc magenta "deleting remote tags and branches from \"${remote}\""
  while read RemoteRef ; do
    if [[ $RemoteRef =~ ^([a-fA-F0-9]*).+(refs/[^/]+/.+)$ ]] ; then

      ref_hash="${BASH_REMATCH[1]}"
      ref_name="${BASH_REMATCH[2]}"

      # skip annotated tags: they are automatically deleted
      l=$(( ${#ref_name} - 3 ))
      [[ ${ref_name:$l} == '^{}' ]] && continue

      # skip current HEAD
      if [[ $ref_hash == $ref_head ]] ; then
        prc magenta "not deleting from \"${remote}\" reference \"${ref_name}\": it is the current HEAD"
        continue
      fi

      prc blue "deleting from \"${remote}\" reference \"${ref_name}\"..."
      fatal git push "${remote}" :"${ref_name}"
    else
      prc red "malformed remote refname: $ref_name - this should not happen, aborting!"
      exit 10
    fi
  done < <( git ls-remote --heads --tags "${remote}" )

)

# force push all branches and tags
function forcepushall() (

  fatal cd "$GitRootSplit"
  remote="$1"

  # ask for confirmation
  right_answer='yes, I intend to proceed!'
  prc red "you are about to do something potentially catastrophic:"
  prc red " - force pushing all local branches to the remote \"${remote}\""
  prc red " - force pushing all tags to the remote \"${remote}\""
  prc red "you must confirm this operation by typing: \"${right_answer}\""
  read -p ':> ' given_answer
  fatal [ "$given_answer" == "$right_answer" ]

  while read local_ref ; do

    if [[ $local_ref =~ ^([a-fA-F0-9]*).+(refs/[^/]+/(.+))$ ]] ; then

      ref_hash="${BASH_REMATCH[1]}"
      ref_name="${BASH_REMATCH[2]}"
      ref_short="${BASH_REMATCH[3]}"

      prc blue "force pushing branch \"${ref_short}\" (${ref_name}) and its tags to remote \"${remote}\"..."
      fatal git push -f --follow-tags "${remote}" "${ref_name}:${ref_short}"

    else
      prc red "malformed local refname: $ref_name - this should not happen, aborting!"
      exit 10
    fi

  done < <( git show-ref --heads )

)

# list all committers and authors along with their emails and a count
function listauth() (

  fatal cd "$GitRootSplit"
  ofile="$1"

  prc magenta "writing list to ${ofile}"

  # %an --> GIT_AUTHOR_NAME
  # %ae --> GIT_AUTHOR_EMAIL
  # %cn --> GIT_COMMITTER_NAME
  # %ce --> GIT_COMMITTER_EMAIL
  while read commit ; do
    git log -1 --no-walk --format="tformat:%cn;%ce%n%an;%ae" $commit
  done < <( git rev-list --all ) | sort | uniq -c | sed -e 's/^\s*\([0-9]\+\) /\1;/' | tee -a "${ofile}"

  prc magenta "list written to ${ofile}"

)

# rewrite authors according to a mapfile
function rewriteauth() (

  fatal cd "$GitRootSplit"
  infile="$1"
  verbose="$2"

  # maps email to author and email
  export mapfile="$infile"
  export verbose
  function _git_auth_map() {

    chcomm=' '
    chauth=' '

    # author
    raw=$( grep "^${GIT_AUTHOR_EMAIL};" "$mapfile" 2> /dev/null | head -n1 | cut -d\; -f2,3 )
    name=${raw%;*}
    email=${raw##*;}
    if [[ $raw != '' && $name != '' && $email != '' ]] ; then
      chauth='*'
      #echo -e "\n\nauthor is changing! $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL> --> $name <$email>"
      export GIT_AUTHOR_NAME=$name
      export GIT_AUTHOR_EMAIL=$email
    fi

    # committer
    if [[ $GIT_AUTHOR_EMAIL != $GIT_COMMITTER_EMAIL ]] ; then
      raw=$( grep "^${GIT_COMMITTER_EMAIL};" "$mapfile" 2> /dev/null | head -n1 | cut -d\; -f2,3 )
    fi
    name=${raw%;*}
    email=${raw##*;}
    if [[ $raw != '' && $name != '' && $email != '' ]] ; then
      chcomm='*'
      #echo -e "committer is changing! $GIT_COMMITTER_NAME <$GIT_COMMITTER_EMAIL> --> $name <$email>\n\n"
      export GIT_COMMITTER_NAME=$name
      export GIT_COMMITTER_EMAIL=$email
    fi

    # messages
    if [[ $verbose == 1 ]] ; then
      echo
      echo "author${chauth}: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL> / committer${chcomm}: $GIT_COMMITTER_NAME <$GIT_COMMITTER_EMAIL>"
    fi

  }
  export -f _git_auth_map

  # want to test on a bunch of commits?
  # --all --> 59820a28155e835bb38f0823ab966c33074fb29a..HEAD (from 598... to HEAD)
  fatal git filter-branch \
    --force \
    --env-filter '_git_auth_map' \
    --tag-name-filter cat -- --all

  unset _git_auth_map mapfile verbose

)

# nice time formatting
function nicetime() (
  t=$1
  hr=$(( t / 3600 ))
  t=$(( t % 3600 ))
  mn=$(( t / 60 ))
  t=$(( t % 60 ))
  sc=$t
  echo "${hr}h ${mn}m ${sc}s"
)

# the main function
function main() (

  while [[ $# -gt 0 ]] ; do
    case "$1" in
      --source)
        GitRootSplit="$2"
        shift
      ;;
      --regexp)
        RegExp="$2"
        shift
      ;;
      --file)
        File="$2"
        shift
      ;;
      --remote)
        Remote="$2"
        shift
      ;;
      --invert-match)
        RegExpInvert=1
      ;;
      --only-root-dir)
        OnlyRootDir=1
      ;;
      --verbose)
        Verbose=1
      ;;
      lsbr)
        do_lsbr=1
      ;;
      updbr)
        do_updbr=1
      ;;
      cleanall)
        do_cleanall=1
      ;;
      rewritehist)
        do_rewritehist=1
      ;;
      rewriteauth)
        do_rewriteauth=1
      ;;
      lsallfiles)
        do_lsallfiles=1
      ;;
      delremoterefs)
        do_delremoterefs=1
      ;;
      listauth)
        do_listauth=1
      ;;
      forcepushall)
        do_forcepushall=1
      ;;
      slimrepo)
        do_slimrepo=1
      ;;
      *)
        prc red "not understood: $1"
        return 1
      ;;
    esac
    shift
  done

  GitRootSplit=$( cd "$GitRootSplit" ; pwd )
  if [[ ! -d "${GitRootSplit}/.git" && ! -f "${GitRootSplit}/HEAD" ]] ; then
    prc red 'set the $GitRootSplit var to the original Git source dir'
    return 1
  fi

  if [[ ${File} == '' ]] ; then
    File=$( mktemp /tmp/ali-split-list-XXXXX )
    TempFile=1
  elif [[ ${File:0:1} != '/' ]] ; then
    File="${PWD}/${File}"
  fi

  if [[ ${Remote} == '' ]] ; then
    prc yellow "no remote set: defaulting to \"origin\""
    Remote='origin'
  fi

  export GitRootSplit
  prc yellow "working on Git source on: $GitRootSplit"

  # process actions in right order, and time them
  ts_start=$( date --utc +%s )
  [[ $do_cleanall == 1 ]] && cleanall
  [[ $do_updbr == 1 ]] && updbr
  [[ $do_lsbr == 1 ]] && lsbr "$Remote"
  [[ $do_listauth == 1 ]] && listauth "$File"
  [[ $do_lsallfiles == 1 ]] && lsallfiles "$RegExp" "$RegExpInvert" "$OnlyRootDir" "$File" "$TempFile"
  [[ $do_rewritehist == 1 ]] && rewritehist "$File" "$Remote"
  [[ $do_rewriteauth == 1 ]] && rewriteauth "$File" "$Verbose"
  [[ $do_slimrepo == 1 ]] && slimrepo
  [[ $do_delremoterefs == 1 ]] && delremoterefs "$Remote"
  [[ $do_forcepushall == 1 ]] && forcepushall "$Remote"
  ts_end=$( date --utc +%s )
  ts_delta=$(( ts_end - ts_start ))

  [[ ${TempFile} == 1 ]] && rm -f "${TempFile}"

  prc magenta "time taken by all operations: $( nicetime $ts_delta )"

)

# entry point
main "$@"
exit $?
