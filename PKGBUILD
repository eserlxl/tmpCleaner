# Maintainer: Eser KUBALI <eserlxl@gmail.com>
pkgname=linux-tmpcleaner
pkgver=1.0.0
pkgrel=1
pkgdesc="Systemd timer that deletes old /tmp entries while protecting files in use"
arch=('any')
url="https://github.com/eserlxl/tmpCleaner"
license=('GPL-3.0-or-later')
depends=('bash' 'coreutils' 'findutils' 'gawk' 'grep' 'sed' 'systemd>=249')
# The unrelated AUR package "tmpcleaner" also ships /usr/bin/tmpcleaner.
conflicts=('tmpcleaner')
backup=('etc/tmpcleaner/tmpcleaner.conf')
install=tmpcleaner.install
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
# Pinned sha256 of the v$pkgver release tarball. After the v$pkgver tag is
# pushed, pin this with `updpkgsums` in a follow-up commit; never publish to
# the AUR with 'SKIP'.
sha256sums=('SKIP')

check() {
  cd "$srcdir/tmpCleaner-$pkgver"
  make test
}

package() {
  cd "$srcdir/tmpCleaner-$pkgver"
  make install DESTDIR="$pkgdir" PREFIX=/usr UNITDIR=/usr/lib/systemd/system
}
