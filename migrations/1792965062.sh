echo "Name the hibernation resume device by its filesystem UUID"

# Hibernation setup named an unencrypted root by its kernel name. With two NVMe
# disks that name can belong to the other disk at the next boot, and resume then
# finds no image and the session is lost. Setup now writes the filesystem UUID,
# and on a configured machine renames the device and rebuilds the boot image.
drop_in=/etc/limine-entry-tool.d/resume.conf
hook=/etc/mkinitcpio.conf.d/omarchy_resume.conf

[[ -f $drop_in ]] && grep -q 'resume=/dev/' "$drop_in" && ! grep -q 'resume=/dev/mapper/' "$drop_in" || exit 0

# Without the resume hook, setup would offer to set hibernation up from scratch.
[[ -f $hook ]] && grep -q '^HOOKS+=(resume)$' "$hook" || exit 0

# Setup puts the old drop-in back if the boot image is not rebuilt and exits 1,
# which leaves this migration pending for the next omarchy-migrate.
omarchy-hibernation-setup
