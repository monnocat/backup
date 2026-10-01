# backup

This is my Advanced Recursive Backup Script of Amazing Awesomeness. It lets you recursively specify everything that needs to be backed up and everything that doesn't.

## Usage

`./backup.sh [-c config] [-o output]`

- `-c config`: Optional. A config file. Defaults to `config.json`.
- `-o output`: Optional. An output file. Defaults to `backup-YYYY_MM_DD-XXXXX.tar.gz`. Supported extensions are `tar.gz` and `zip`.

## Configuration

A config is a JSON object that consists of the following keys:

- `mode`: One of `"all"`/`"include"`/`"exclude"`.
- `include`?: Optional. A list of items to include (if mode is "include"). Items can be included from subdirectories, in which case the intermediate directories will behave as if they were in `include` mode, with the included directories being the ones listed.
- `exclude`?: Optional. A list of items to exclude (if mode is "exclude")
- `configs`?: Optional. A collection of key-value pairs `item: config`. There can be a `"*"` entry, which will be the fallback config for all items that need to be configured. Note that only directories can be configured.

Top level object must have an entrypoint named `start` (does not accept `~`).

You can optionally specify templates at the top level, whose names can be used in place of configs.
