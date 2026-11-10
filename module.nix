{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.rclone-mounts;

  rcCredentialsFile = name: "/var/lib/rclone/rc-${name}.env";
  rcMounts = builtins.filter (mount: mount.rc-port != null) cfg.mounts;

  # Flags the module needs on every mount. `tuned` adds the two that belong to
  # the per-type flag sets below and stay in this position for stable units.
  baseFlags =
    mount: tuned:
    [
      "--config=${cfg.configPath}"
      "--cache-dir=${cfg.cacheDir}/${mount.target}"
      "--allow-other"
    ]
    ++ lib.optionals tuned [
      "--allow-non-empty"
      "--log-level=ERROR"
    ]
    # The rc API can read and write any host path as root, so it always
    # requires the generated credentials (read from RCLONE_RC_USER/PASS).
    ++ lib.optionals (mount.rc-port != null) [
      "--rc"
      "--rc-addr=0.0.0.0:${toString mount.rc-port}"
    ];

  typeFlags = {
    gdrive = [
      "--attr-timeout=8700h"
      "--use-mmap"
      "--stats=10s"
      "--buffer-size=32M"
      "--poll-interval=30s"
      "--dir-cache-time=8700h"
      "--drive-server-side-across-configs"
      "--vfs-cache-mode=full"
      "--vfs-read-chunk-size=32M"
      "--vfs-read-chunk-size-limit=1G"
      "--vfs-case-insensitive"
      "--vfs-cache-max-size=2G"
      "--vfs-cache-max-age=4h"
      "--vfs-cache-poll-interval=30s"
      "--local-no-check-updated"
      "--drive-chunk-size=64M"
      "--multi-thread-streams=4"
      "--multi-thread-cutoff=250M"
      "--timeout=1m"
      "--drive-pacer-min-sleep=10ms"
      "--drive-pacer-burst=200"
    ];
    sftp = [
      "--buffer-size=32M"
      "--dir-cache-time=1m"
      "--vfs-cache-mode=full"
      "--vfs-read-chunk-size=32M"
      "--vfs-read-ahead=128M"
      # Minimum free space on the disk that holds the cache.
      "--vfs-cache-min-free-space=15G"
      "--vfs-cache-max-age=168h"
      "--vfs-cache-poll-interval=30s"
      "--transfers=6"
      "--vfs-fast-fingerprint"
      "--use-server-modtime"
    ];
  };

  ownerFlags =
    mount:
    lib.optionals (mount.uid != null) [
      "--uid=${toString mount.uid}"
      "--gid=${toString mount.uid}"
      "--umask=0077"
      "--default-permissions"
    ];

  mountFlags =
    mount:
    baseFlags mount (mount.flags == null)
    ++ (if mount.flags == null then typeFlags.${mount.type} else mount.flags)
    ++ ownerFlags mount
    ++ mount.extraFlags;

  mountService =
    mount:
    let
      name = mount.target;
    in
    {
      description = "Mount ${mount.source}:/ to /mnt/${name}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = lib.optional (mount.rc-port != null) "rclone-rc-${name}-credentials.service";
      serviceConfig =
        lib.optionalAttrs (mount.rc-port != null) {
          EnvironmentFile = rcCredentialsFile name;
        }
        // {
          ExecStartPre = pkgs.writeScript "rclone-mount-pre-${name}" ''
            #!/bin/sh
            /run/wrappers/bin/fusermount -u /mnt/${name} || true
            ${pkgs.coreutils}/bin/mkdir -p /mnt/${name} || true
            exit 0
          '';
          # rclone exits at once when it cannot reach the remote, for example
          # while DNS restarts during a system switch. Retry for about a minute
          # while each attempt dies within 10 seconds. A mount that ran longer
          # had come up, so its exit ends the unit and systemd restarts it.
          ExecStart = pkgs.writeScript "rclone-mount-${name}" ''
            #!/bin/sh
            attempt=1
            while :; do
              started=$(${pkgs.coreutils}/bin/date +%s)
              ${cfg.package}/bin/rclone mount ${
                lib.escapeShellArgs (
                  [
                    mount.source
                    "/mnt/${name}"
                  ]
                  ++ mountFlags mount
                )
              }
              status=$?
              elapsed=$(($(${pkgs.coreutils}/bin/date +%s) - started))
              if [ "$status" -eq 0 ] || [ "$elapsed" -ge 10 ] || [ "$attempt" -ge 10 ]; then
                exit "$status"
              fi
              echo "rclone: mounting /mnt/${name} failed after ''${elapsed}s, retrying ($attempt/10)" >&2
              attempt=$((attempt + 1))
              ${pkgs.coreutils}/bin/sleep 5
              # A mount that died young can leave a dead FUSE mount behind.
              /run/wrappers/bin/fusermount -u /mnt/${name} 2>/dev/null || true
            done
          '';
          # Hold the unit in "activating" until the FUSE mount is actually established,
          # so units ordered After=/Requires= this one only start once /mnt/${name}
          # is a real mountpoint (rclone attaches it within ~1s). Fixes containers
          # racing ahead of the mount and dying on statfs.
          ExecStartPost = pkgs.writeScript "rclone-mount-wait-${name}" ''
            #!/bin/sh
            for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
              ${pkgs.util-linux}/bin/mountpoint -q /mnt/${name} && exit 0
              ${pkgs.coreutils}/bin/sleep 1
            done
            echo "rclone: /mnt/${name} did not become a mountpoint within 60s" >&2
            exit 1
          '';
          ExecStop = pkgs.writeScript "rclone-mount-pre-${name}" ''
            #!/bin/sh
            /run/wrappers/bin/fusermount -u /mnt/${name} || true
            exit 0
          '';
          Restart = "always";
          RestartSec = "10s";
        };
      wantedBy = [ "multi-user.target" ];
    };

  # Generated once and kept, so clients holding the file keep working across
  # restarts. Delete the file and restart the mount to rotate.
  rcCredentialService = mount: {
    description = "Generate rclone rc credentials for /mnt/${mount.target}";
    before = [ "${mount.target}-mnt.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "rclone";
      StateDirectoryMode = "0700";
      UMask = "0077";
    };
    script = ''
      file=${rcCredentialsFile mount.target}
      if [ ! -s "$file" ]; then
        pass=$(${pkgs.openssl}/bin/openssl rand -hex 32)
        printf 'RCLONE_RC_USER=rclone\nRCLONE_RC_PASS=%s\n' "$pass" > "$file.tmp"
        mv "$file.tmp" "$file"
      fi
    '';
  };

  healthcheckService = mount: {
    description = "Healthcheck for /mnt/${mount.target} rclone mount";
    after = [ "${mount.target}-mnt.service" ];
    # Skip rather than start the mount. A Requires= here let the
    # every-minute timer restart a mount switch-to-configuration had just
    # stopped, before its daemon-reload, so the mount kept its old unit.
    unitConfig.ConditionPathIsMountPoint = "/mnt/${mount.target}";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeScript "rclone-healthcheck-${mount.target}" ''
        #!/bin/sh
        # Try to stat the mount point with a 10s timeout.
        # If the FUSE mount is stale, stat will hang indefinitely.
        if ! ${pkgs.coreutils}/bin/timeout 10 ${pkgs.coreutils}/bin/stat /mnt/${mount.target} >/dev/null 2>&1; then
          echo "Mount /mnt/${mount.target} is unresponsive, restarting ${mount.target}-mnt.service"
          /run/wrappers/bin/fusermount -u /mnt/${mount.target} || true
          systemctl restart ${mount.target}-mnt.service
        fi
      '';
    };
  };

  healthcheckTimer = mount: {
    description = "Timer for /mnt/${mount.target} rclone mount healthcheck";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
      AccuracySec = "10s";
    };
  };

  unitsFor = suffix: mk: map (mount: lib.nameValuePair "${mount.target}${suffix}" (mk mount));
in
{
  options.services.rclone-mounts = {
    package = lib.mkPackageOption pkgs "rclone" { };

    mounts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              example = "gdrive:/";
              description = "The remote and path to mount, as named in the rclone config.";
            };

            target = lib.mkOption {
              type = lib.types.str;
              example = "drive";
              description = ''
                Name of the mount. The mount point is `/mnt/<target>` and the
                systemd unit is `<target>-mnt.service`.
              '';
            };

            type = lib.mkOption {
              type = lib.types.enum [
                "gdrive"
                "sftp"
              ];
              description = "Which tuned flag set the mount uses, unless `flags` replaces it.";
            };

            flags = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              example = [
                "--vfs-cache-mode=full"
                "--vfs-cache-max-size=4G"
              ];
              description = ''
                Replaces the tuned flag set for `type`, including its
                `--allow-non-empty` and `--log-level=ERROR`. The module still
                adds `--config`, `--cache-dir`, `--allow-other`, the rc flags
                and the ownership flags.
              '';
            };

            extraFlags = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "--vfs-read-ahead=1G" ];
              description = ''
                Flags appended after everything else. rclone takes the last
                value of a repeated flag, so these override the flag set.
              '';
            };

            rc-port = lib.mkOption {
              type = lib.types.nullOr lib.types.port;
              default = null;
              example = 5572;
              description = ''
                If set, serves rclone's remote-control API on this port on all
                addresses, behind basic auth. The credentials are generated on the
                host; see `services.rclone-mounts.rcCredentials`.
              '';
            };

            uid = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              example = 900;
              description = ''
                UID and GID of a dedicated `rclone-<target>` system user that owns
                every file on the mount. The kernel then enforces 0700/0600
                permissions, so only root and this UID (for example a container
                user mapped onto it) can read or write. Null keeps the mount
                readable and writable by every local user.
              '';
            };
          };
        }
      );
      default = [ ];
      description = "The rclone mounts to create, each as a system service under `/mnt`.";
      example = lib.literalExpression ''
        [
          {
            source = "gdrive:/";
            target = "drive";
            type = "gdrive";
          }
          {
            source = "storagebox:backups";
            target = "backups";
            type = "sftp";
            uid = 900;
            rc-port = 5572;
          }
        ]
      '';
    };

    configPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/rclone_conf";
      description = ''
        Path to the rclone config file read at mount time; required when
        mounts are set. Keep it out of the Nix store: point this at a secret
        decrypted at boot, and make it writable by root if a remote refreshes
        OAuth tokens.
      '';
    };

    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/tmp/rclone";
      description = ''
        Parent directory for each mount's VFS cache (`<cacheDir>/<target>`).
        Move it off /tmp on hosts where /tmp is a tmpfs, or the caches live in RAM.
      '';
    };

    rcCredentials = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = lib.listToAttrs (
        map (mount: lib.nameValuePair mount.target (rcCredentialsFile mount.target)) rcMounts
      );
      defaultText = lib.literalExpression ''{ <target> = "/var/lib/rclone/rc-<target>.env"; }'';
      description = ''
        Root-only environment files holding RCLONE_RC_USER and RCLONE_RC_PASS
        for each mount with rc-port set, keyed by target. They are generated
        once on the host. Give one to a client (e.g. as a container
        environmentFile) that must call the rc API.
      '';
    };
  };

  config = {
    environment.systemPackages = lib.optional (cfg.mounts != [ ]) cfg.package;

    users = lib.mkMerge (
      map (
        mount:
        let
          owner = "rclone-${mount.target}";
        in
        lib.mkIf (mount.uid != null) {
          users.${owner} = {
            isSystemUser = true;
            inherit (mount) uid;
            group = owner;
            description = "Owner of the /mnt/${mount.target} rclone mount";
          };
          groups.${owner}.gid = mount.uid;
        }
      ) cfg.mounts
    );

    assertions = [
      {
        assertion = cfg.mounts == [ ] || cfg.configPath != null;
        message = "services.rclone-mounts.mounts requires services.rclone-mounts.configPath.";
      }
    ];

    systemd.services = builtins.listToAttrs (
      unitsFor "-mnt" mountService cfg.mounts
      ++ unitsFor "-mnt-healthcheck" healthcheckService cfg.mounts
      ++ map (
        mount: lib.nameValuePair "rclone-rc-${mount.target}-credentials" (rcCredentialService mount)
      ) rcMounts
    );
    systemd.timers = builtins.listToAttrs (unitsFor "-mnt-healthcheck" healthcheckTimer cfg.mounts);
  };
}
