
## A Bash script to manage files on Remarkable devices via C.L.I. and S.S.H.

Remarkable's local A.P.I. and web interface are slow and lack essential features. I don't like cloud services and I couldn't find a script that worked, so I wrote my own. This is a work in progress but it already works very well for me. Please report any issues-- there may be differences between product models, software versions, and personal workflows.

### Known to work with:
- Remarkable Paper Pro (3.24.0.149)

### Dependencies:

- Bash (probably at least version 5.0).
- ssh.
- rsync.
- jq.
- find.
- sed.


## Usage:

Syntax, operations, parameters, and some introductory notes are all output by `remarkable-ssh help`. In fact, the `help` is optional. What I have written here is intended to give prospective users a sense for what this script can do.

### Operations:

- `Help` by printing usage information.
- `Cache` scope operations.
  - `Push` cache directory to Remarkable device.
    - `Diff` (rsync format)
  - `Pull` from Remarkable device to cache directory.
    - `Diff` (rsync format)
  - `Diff` (neutral table format)
- `List` objects, optionally within a folder and with optional recursive depth limit.
- `Add` files of supported types.
- `Rename` objects.
- `Delete` objects.
- `Make folder` objects.
- `Move objects` with respect to folders.

### Parameters:

- `Path` to cache directory.
- S.S.H. `host` value for Remarkable device.
- `Config` file path.
- Do `not add` new things.
- Do `not delete` anything.
- `Only add` new things.
- `Only delete` removed things.
- `Include unsupported` file types.

Running `cache push` or `cache push` without any sync-related parameters will perform a full sync, including additions, deletions, and updates. Only updates can be achieved by specifying both `--no-add` and `--no-delete`.


## Set-up:

For this script to work, you will need S.S.H. access to your Remarkable device.

In theory, this should work on any operating system so long as the dependencies listed above are available. I do not know what Windows Subsystem for Linux provides. I have described the requirements for and process of connecting to Remarkable devices from a Linux host [here](https://wiki.gentoo.org/wiki/User:Penguin-Guru/Remarkable). Note that distribution kernels probably already support the necessary drivers and do not need to be rebuilt.

Once you've downloaded this script, run its `help` operation to get started. You are responsible for knowing what the commands you run will do. I strongly suggest running the `diff` sub-operations before any `push` or `pull` operations. This prints out what changes would be made without actually making them.

You may also want to create a backup of the files on your device. That can be achieved by running `remarkable-ssh --cache=<path_to_backup_directory> --host=<ssh_target> --unsupported-files cache pull`, where the backup cache directory specified is different from the cache directory you will normally be using. If you need to restore from the backup directory, just run the same command with `push` instead of `pull`.

### Config file:

Since the `--cache` and `--host` parameters must be specified for many operations, most users will want to define them in the optional config file.

Unless otherwise specified (by the `--config` parameter), the script will look for a file named "remarkable-ssh.conf" in either "$XDG_CONFIG_HOME" (if defined) or (otherwise) "~/.config".

The config file syntax is very simple:
- Lines must take the form of: `<parameter_name>[=<value>]`
- Whitespace leading and trailing each line is trimmed.
- Whitespace surrounding the '=' symbol is trimmed.
- If the first non-whitespace character on a line is the '[#](https://en.wikipedia.org/wiki/Number_sign)' symbol, the line is ignored.
- If the first character in a value string is a [tilde (~)](https://en.wikipedia.org/wiki/Tilde), it is replaced with the value of "$HOME" (if defined and not empty).

