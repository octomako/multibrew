# multibrew

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](...)
![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-black)
![Shell](https://img.shields.io/badge/Shell-Bash-blue)

share one Homebrew installation between trusted administrator accounts on macOS

<p align="center">
  <img src="assets/demo.gif" alt="multibrew demo">
</p>

> [!WARNING]
> multibrew only supports Apple Silicon Macs


## why?

Homebrew is normally owned by a single user. on Macs with multiple trusted administrator accounts, this often leads to seperate Homebrew installations for each user

**multibrew** configures a single shared Homebrew installation so every trusted administrator uses the same packages, casks, and updates


## features

- share one Homebrew installation between trusted administrator accounts
- uses the local `multibrew` group
- install or adopt an existing Homebrew installation
- doesn't run Homebrew as root
- simple install and removal


## install

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/octomako/multibrew/main/install.sh)"
```

```bash
sudo multibrew mount
```


## commands

| command   | description                                     |
| --------- | ----------------------------------------------- |
| `mount`   | install or adopt a shared Homebrew installation |
| `status`  | show current configuration                      |
| `members` | manage shared users                             |
| `repair`  | restore permissions after membership changes    |
| `update`  | update multibrew                                |
| `unmount` | disable sharing while keeping Homebrew          |
| `erase`   | remove Homebrew and shared configuration        |


## managing members

`mount` lets you choose administrator accounts during setup

you can later manage members with:

```bash
sudo multibrew members
```

if group membership is changed outside multibrew, run:

```bash
sudo multibrew repair
```

users should sign out and back in for the changes to take effect


## security

- every multibrew member can modify software used by every other member
- only add trusted administrator accounts
- multibrew never runs Homebrew itself as root
- root access is used for system configuration, permissions, group management, and cleanup


## uninstall

only remove the `multibrew` command:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/octomako/multibrew/main/uninstall.sh)"
```

disable sharing but keep homebrew:

```bash
sudo multibrew unmount
```

remove the shared homebrew installation and multibrew configuration:

```bash
sudo multibrew erase
```
