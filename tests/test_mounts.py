import unittest

import collector


class MountTests(unittest.TestCase):
    def test_mount_points_dedupe_devices_and_skip_boot(self):
        raw = "\n".join([
            "/dev/mapper/root / btrfs rw 0 0",
            "/dev/mapper/root /home btrfs rw 0 0",
            "/dev/sdb1 /boot vfat rw 0 0",
            "/dev/sda1 /run/media/me/My\\040Games ntfs3 rw 0 0",
            "tmpfs /tmp tmpfs rw 0 0",
            "proc /proc proc rw 0 0",
        ])
        self.assertEqual(collector.mount_points(raw), ["/", "/run/media/me/My Games"])

    def test_mount_usage_labels_root_as_sys(self):
        mounts = collector.mount_usage(["/"])
        self.assertEqual(mounts[0]["label"], "SYS")
        self.assertGreater(mounts[0]["total"], 0)


if __name__ == "__main__":
    unittest.main()
