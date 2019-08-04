# mcshl

[WIP] yet another minecraft launcher, but in shell

## Dependencies

* Any POSIX-compatible shell
* jq
* wget
* curl
* cut, tr, sha1sum, mkdir, ls ... basic commands that almost always exist
* java for launching minecraft

## Current features

* download
* launch
* checksum (except natives and the version json)

## Not implemented yet

* auth and those things that need auth
* delete/ clean
* older formats

## Usage

```
Usage: mcshl.sh [-b BASEDIR | --basedir BASEDIR]
                [-v | --verbose] SUBCOMMAND

  -b, --basedir BASEDIR   Use BASEDIR instead of ~/.minecraft
  -v, --verbose           Increase verbosity

Subcommands:
  rls [-s | --snapshot]
  List Minecraft versions available for download
    -s, --snapshot        Enable snapshots

  lls
  List installed Minecraft versions
  alias: ls

  dl VERSION
  Download Minecraft VERSION
  alias: download

  launch VERSION USERNAME
  Launch Minecraft VERSION with USERNAME

  cksum VERSION
  Check VERSION files with sha1sum, remove if bad
  alias: check, checksum
```
