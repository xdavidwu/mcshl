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

  lls [-a | --asset]
  List installed Minecraft versions
    -a, --asset           Also list asset used
  alias: ls

  dl VERSION
  Download Minecraft VERSION
  alias: download

  launch VERSION USERNAME
  Launch Minecraft VERSION with USERNAME

  cksum VERSION
  Check VERSION files with sha1sum, remove if bad
  alias: check, checksum

  rm_main VERSION
  Remove main jar, json and natives for VERSION
  alias: rm

  lls_asset
  List installed asset versions
  alias: lsasset

  rm_asset VERSION
  Remove asset VERSION, this may break other versions that share
  the same files and need to download with dl again
  alias: rmasset
```
