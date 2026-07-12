# multibrew

multibrew shares one Homebrew installation between trusted administrator accounts on Apple Silicon macOS
it installs as a normal command at `/usr/local/bin/multibrew`

## install

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/octomako/multibrew/main/install.sh)"
```

then mount shared Homebrew

```bash
sudo multibrew mount
```

## commands

```text
sudo multibrew mount
sudo multibrew unmount
sudo multibrew repair
sudo multibrew update
sudo multibrew members
sudo multibrew status
sudo multibrew erase
```

`mount` installs or adopts Homebrew and enables shared access
`unmount` removes shared access and keeps Homebrew for the original owner
`erase` removes Homebrew and the shared setup but keeps the multibrew command

## members

multibrew always uses the local `multibrew` group

`sudo multibrew mount` lets you select administrator accounts during setup
`sudo multibrew members` can add users, remove users, or open Users & Groups

the group can also be edited directly in System Settings under Users & Groups
run this after changing membership in System Settings

```bash
sudo multibrew repair
```

changed users must sign out and back in before using Homebrew

## remove the command

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/octomako/multibrew/main/uninstall.sh)"
```

this only removes `/usr/local/bin/multibrew`

use `sudo multibrew unmount` first to keep Homebrew without sharing
use `sudo multibrew erase` first to remove Homebrew too

## security

- every multibrew member can modify software used by every other member
- only add trusted local administrators
- multibrew never runs Homebrew itself as root
- root access is used for system configuration, permissions, group management, and cleanup
- complete cask data cleanup can require Full Disk Access for the terminal