// QR Code generation hook using qrcode-generator library.
// Bundled into app.js via esbuild (no separate <script> tag / request).
import qrcode from "../vendor/qrcode.min.js";

const QRCodeHook = {
  mounted() {
    const data = this.el.dataset.lnurl;
    if (data) {
      this.renderQR(data);
    }
  },

  updated() {
    const data = this.el.dataset.lnurl;
    if (data) {
      this.renderQR(data);
    }
  },

  renderQR(data) {
    // Use qrcode-generator with error correction level M (15% recovery).
    // Type 0 = auto-select version based on data length.
    const qr = qrcode(0, 'M');
    qr.addData(data);
    qr.make();

    // Create SVG for crisp rendering at any size
    // IMPORTANT: Use white background with white quiet zone for scanner compatibility
    const moduleCount = qr.getModuleCount();
    const cellSize = 4;
    const quietZone = 4; // 4 module quiet zone (QR spec minimum)
    const margin = quietZone * cellSize;
    const size = moduleCount * cellSize + margin * 2;

    let svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size} ${size}" width="${size}" height="${size}" class="qr-image">`;
    // White background for scanner compatibility (quiet zone requirement)
    svg += `<rect width="${size}" height="${size}" fill="#ffffff"/>`;

    for (let row = 0; row < moduleCount; row++) {
      for (let col = 0; col < moduleCount; col++) {
        if (qr.isDark(row, col)) {
          const x = margin + col * cellSize;
          const y = margin + row * cellSize;
          svg += `<rect x="${x}" y="${y}" width="${cellSize}" height="${cellSize}" fill="#000000"/>`;
        }
      }
    }

    svg += '</svg>';
    this.el.innerHTML = svg;
  }
};

export default QRCodeHook;
