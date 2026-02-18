
## A Bash script to manage files on Remarkable devices via C.L.I. and S.S.H.

Remarkable's local A.P.I. and web interface are slow and lack essential features. I don't like cloud services and I couldn't find a script that worked, so I wrote my own. This is a work in progress but it already works very well for me. Please report any issues-- there may be differences between product models, software versions, and personal workflows.

So far, known to work with:
- Remarkable Paper Pro (3.24.0.149)


### Dependencies:

- Bash (probably at least version 5.0).
- ssh.
- rsync.
- jq.
- find.
- sed.


### Usage:

## Operations:

- Help
- Cache
  - Push
    - Diff
  - Pull
    - Diff
  - Diff (table format)
- List
- Add
- Rename
- Delete
- Mkdir
- Move

## Parameters:

- Path to cache directory.
- S.S.H. host value for Remarkable device.
- Do not add new things.
- Do not delete anything.
- Only add new things.
- Only delete removed things.
- Include unsupported file types.


### Set-up:

For this script to work, you will need S.S.H. access to your Remarkable device.

I've described the requirements for and process of connecting to Remarkable devices from a Linux host [here](https://wiki.gentoo.org/wiki/User:Penguin-Guru/Remarkable). Note that distribution kernels probably already support the necessary drivers and do not need to be rebuilt. In theory, this should work on any operating system so long as the dependencies listed above are available. I do not know what Windows Subsystem for Linux provides.

Once you've downloaded this script, run its `help` operation to get started. You are responsible for knowing what the commands you run will do. I strongly suggest running the `diff` sub-operations before any `push` or `pull` operations. This prints out what changes would be made without actually making them.

