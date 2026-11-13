#!/usr/bin/env bash
# A mistyped disk passphrase no longer ends the boot. New installs put
# tries=0 in rd.luks.options, so systemd-cryptsetup asks again until the
# passphrase is right. Before, the third wrong one dropped the initrd to an
# emergency shell that the locked root account cannot open. Add the option
# to an earlier install's kernel command line and rebuild the boot images
# that carry it. A command line that already sets tries= is left alone, as
# is one without rd.luks.options.
# SUBCULT_TEST_ROOT: a stand-in filesystem root for tools/test/migration-luks-tries-test.sh.
root=${SUBCULT_TEST_ROOT:-}
files=()
for f in "$root/etc/default/limine" "$root/etc/kernel/cmdline"; do
  [[ -f $f ]] || continue
  grep -q 'rd\.luks\.options=' "$f" || continue
  grep -q 'rd\.luks\.options=[^[:space:]"]*tries=' "$f" && continue
  files+=("$f")
done
((${#files[@]})) || exit 0
echo "The disk passphrase prompt now asks again after a wrong passphrase (tries=0); rebuilding the boot images."
sudo sed -i '/rd\.luks\.options=/{/rd\.luks\.options=[^[:space:]"]*tries=/!s/\(rd\.luks\.options=[^[:space:]"]*\)/\1,tries=0/}' "${files[@]}"
# Limine reads the command line from /etc/default/limine into each UKI and
# its menu entry; snapshots keep the line they were made with. If the
# rebuild fails, take the option out again, so the next run finds the
# command line unchanged and rebuilds then.
if ! sudo limine-mkinitcpio; then
  sudo sed -i 's/\(rd\.luks\.options=[^[:space:]"]*\),tries=0/\1/' "${files[@]}"
  echo "The boot images could not be rebuilt; the kernel command line is as it was." >&2
  exit 1
fi
