Step 1: Partition the Disk
You'll need to create a partition table and at least one partition on the nvme0n1 disk. gdisk (for GPT) or fdisk (for MBR) are common tools. For a 1.5TB drive, GPT (GUID Partition Table) is highly recommended as MBR has limitations on disk size (up to 2TB).

Start gdisk (GPT Partitioning Tool):

Bash

sudo gdisk /dev/nvme0n1
Create a New Partition Table (if not already GPT):

If it's a brand new disk or you want to wipe any existing partition structure, type o (for "create a new empty GPT partition table") and press Enter.
Confirm with y if prompted.
Create a New Partition:

Type n (for "new partition") and press Enter.
Partition number: Press Enter for the default (usually 1).
First sector: Press Enter for the default (start of the disk).
Last sector: Press Enter for the default (end of the disk) to use the entire 1.5TB.
Hex code or GUID: Press Enter for the default (8300 for Linux filesystem) or type 8E00 if you plan to use LVM later. For direct use, 8300 is fine.
Write Changes and Exit:

Type w (for "write table to disk") and press Enter.
Confirm with y when prompted to save changes and exit.
Step 2: Create a Filesystem on the New Partition
After partitioning, you'll have a new partition device, likely /dev/nvme0n1p1. Now you need to format it with a filesystem. ext4 or xfs are common choices for Linux.

Create an ext4 filesystem:
Bash

sudo mkfs.ext4 /dev/nvme0n1p1
You can replace ext4 with xfs if you prefer: sudo mkfs.xfs /dev/nvme0n1p1
Step 3: Create a Mount Point
You need an empty directory where you'll "attach" the filesystem to your Linux system's file tree.

Bash

sudo mkdir /mnt/nvmedata
(You can choose any path you like, /mnt/ or /data/ are common locations for additional drives).

Step 4: Mount the Filesystem
Now you can mount the newly formatted partition to your mount point.

Bash

sudo mount /dev/nvme0n1p1 /mnt/nvmedata
Step 5: Verify the Mount
Check if the disk is correctly mounted and available.

Bash

df -h /mnt/nvmedata
You should see /dev/nvme0n1p1 listed with its size and usage.

Step 6: Make it Mount Automatically on Boot (Optional, but Recommended for permanent use)
To ensure the disk is mounted every time your system starts, you need to add an entry to /etc/fstab. Using the UUID is more robust than using the device name (/dev/nvme0n1p1) because device names can sometimes change.

Get the UUID of the new partition:

Bash

sudo blkid /dev/nvme0n1p1
Look for the UUID="..." part in the output.

Edit /etc/fstab:

Bash

sudo nano /etc/fstab # or use your preferred text editor like vi, vim
Add a new line to the end of the file:

UUID=<your_uuid_here> /mnt/nvmedata ext4 defaults 0 2
Replace <your_uuid_here> with the actual UUID you got from blkid.
Ensure ext4 matches the filesystem type you created.
defaults: Standard mounting options.
0: Do not dump filesystem.
2: Check filesystem at boot (after root filesystem).
Save and exit the editor.

Test the fstab entry (without rebooting):

Bash

sudo mount -a
This command attempts to mount all filesystems listed in /etc/fstab that are not already mounted. If there are no errors, your entry is correct.
