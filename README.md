# rclone-mounts.nix

A simple NixOS module for rclone mounts that run as system services, with a per-mount owner and a health check that restarts a hung mount

```nix
services.rclone-mounts = {
  configPath = "/run/secrets/rclone_conf";
  mounts = [
    {
      source = "gdrive:/";
      target = "drive";
      type = "gdrive";
    }
  ];
};
```

That mounts the `gdrive` remote at `/mnt/drive` as `drive-mnt.service`.

## About

nixpkgs has the `mount.rclone` helper but no service module, and Home Manager's `programs.rclone` makes user mounts. I wanted system mounts that containers can depend on, so this module gives each mount:

- a systemd service, `<target>-mnt.service`, that only reports started once `/mnt/<target>` is a real mount point, so a unit ordered after it never sees an empty directory
- a timer that runs `stat` on the mount every minute and restarts the service if it doesn't answer within 10 seconds
- optionally its own `rclone-<target>` user, so only root and that UID can read the files
- optionally rclone's remote-control API behind basic auth, with credentials generated on the host

This is what I run on my own servers. It isn't a general rclone wrapper, and I'm not promising support, but feel free to open an issue or a PR.

## Installation

1. Add the flake input

   ```nix
   inputs.rclone-mounts = {
     url = "github:dan-online/rclone-mounts.nix";
     inputs.nixpkgs.follows = "nixpkgs";
   };
   ```

2. Import the module in your host

   ```nix
   imports = [ inputs.rclone-mounts.nixosModules.default ];
   ```

3. Point `configPath` at an rclone config that lives outside the Nix store, for example a sops-nix or agenix secret. Google Drive refreshes its OAuth token, so root needs to be able to write to the file.

## Usage

```nix
services.rclone-mounts = {
  configPath = config.sops.secrets.rclone_conf.path;
  cacheDir = "/var/cache/rclone";
  mounts = [
    {
      source = "storagebox:photos";
      target = "photos";
      type = "sftp";
      # Only root and UID 900 can read /mnt/photos.
      uid = 900;
      # rc API on port 5572, credentials in /var/lib/rclone/rc-photos.env.
      rc-port = 5572;
      extraFlags = [ "--vfs-read-ahead=1G" ];
    }
  ];
};
```

`type` picks a set of flags I've tuned for Google Drive or SFTP. `extraFlags` go after that set, and rclone takes the last value of a repeated flag, so they override it. If you'd rather start from nothing, `flags` replaces the set and leaves only the flags the module needs.

To give a container the rc credentials, pass it `config.services.rclone-mounts.rcCredentials.photos` as an environment file. It holds `RCLONE_RC_USER` and `RCLONE_RC_PASS`. Delete the file and restart the mount to rotate them.

## Options

Everything is under `services.rclone-mounts`.

| Option | Default | What it does |
| --- | --- | --- |
| `package` | `pkgs.rclone` | The rclone package |
| `configPath` | `null` | Path to the rclone config, required once you set a mount |
| `cacheDir` | `/tmp/rclone` | Parent of each mount's VFS cache. Move it if `/tmp` is a tmpfs |
| `rcCredentials` | read-only | Credential file for each mount with `rc-port`, keyed by target |
| `mounts.*.source` | | Remote and path from the rclone config |
| `mounts.*.target` | | Name of the mount, mounted at `/mnt/<target>` |
| `mounts.*.type` | | `gdrive` or `sftp` |
| `mounts.*.flags` | `null` | Replaces the flag set for `type` |
| `mounts.*.extraFlags` | `[ ]` | Flags added after everything else |
| `mounts.*.uid` | `null` | UID and GID of a dedicated `rclone-<target>` owner |
| `mounts.*.rc-port` | `null` | Port for the authenticated rc API, on all addresses |

## Not for you if

- you want mounts in your user session, Home Manager's `programs.rclone` does that
- you need a mount point outside `/mnt`
- you're not on NixOS. The units call `/run/wrappers/bin/fusermount`

## Testing

`nix flake check` boots a NixOS VM, mounts a local directory, kills the mount, then freezes it, and checks that it comes back both times.

## License

[MIT](LICENSE)
