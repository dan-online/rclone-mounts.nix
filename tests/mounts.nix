{
  name = "rclone-mounts";

  nodes.machine =
    { pkgs, ... }:
    {
      # The local backend needs no remotes, so the config file is empty.
      environment.etc."rclone.conf".text = "";
      systemd.tmpfiles.rules = [
        "d /srv/data 0755 root root -"
        "f /srv/data/hello 0644 root root - hello"
        "d /srv/tuned 0755 root root -"
      ];

      services.rclone-mounts = {
        configPath = "/etc/rclone.conf";
        mounts = [
          {
            source = "/srv/data";
            target = "data";
            type = "sftp";
            flags = [ "--vfs-cache-mode=writes" ];
            extraFlags = [ "--dir-cache-time=5s" ];
            uid = 900;
            rc-port = 5572;
          }
          # The tuned flag sets must keep parsing as rclone moves.
          {
            source = "/srv/tuned";
            target = "tuned-sftp";
            type = "sftp";
          }
          {
            source = "/srv/tuned";
            target = "tuned-gdrive";
            type = "gdrive";
          }
        ];
      };

      environment.systemPackages = [ pkgs.curl ];
    };

  testScript = ''
    def main_pid():
        return machine.succeed("systemctl show -p MainPID --value data-mnt.service").strip()

    def wait_for_new_mount(old_pid):
        machine.wait_until_succeeds(
            f'test "$(systemctl show -p MainPID --value data-mnt.service)" != {old_pid}'
            " && timeout 5 grep -q hello /mnt/data/hello",
            timeout=300,
        )

    machine.wait_for_unit("data-mnt.service")
    machine.wait_for_unit("tuned-sftp-mnt.service")
    machine.wait_for_unit("tuned-gdrive-mnt.service")

    with subtest("the mount answers and belongs to its own user"):
        machine.succeed("mountpoint -q /mnt/data")
        machine.succeed("grep -q hello /mnt/data/hello")
        assert machine.succeed("stat -c %U:%G /mnt/data/hello").strip() == "rclone-data:rclone-data"
        machine.succeed("mountpoint -q /mnt/tuned-sftp && mountpoint -q /mnt/tuned-gdrive")

    with subtest("the rc API needs the generated credentials"):
        machine.wait_for_open_port(5572)
        machine.succeed("test \"$(stat -c %a /var/lib/rclone/rc-data.env)\" = 600")
        machine.fail("curl -sf -X POST http://127.0.0.1:5572/core/version")
        machine.succeed(
            ". /var/lib/rclone/rc-data.env && "
            'curl -sf -u "$RCLONE_RC_USER:$RCLONE_RC_PASS" -X POST http://127.0.0.1:5572/core/version'
        )

    with subtest("systemd restarts a killed mount"):
        pid = main_pid()
        machine.succeed(f"kill -KILL {pid}")
        wait_for_new_mount(pid)

    with subtest("the health timer restarts a hung mount"):
        pid = main_pid()
        machine.succeed(f"kill -STOP {pid}")
        # The hang is real: reads block until the timer steps in.
        machine.wait_until_fails("timeout 5 stat /mnt/data/hello", timeout=60)
        wait_for_new_mount(pid)
        machine.succeed("journalctl -u data-mnt-healthcheck.service | grep -q 'is unresponsive'")
  '';
}
