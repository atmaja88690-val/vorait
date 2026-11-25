/** Token warna Design §5: biru tua (primer), cyan (info), lime (selesai), maroon (bahaya), ungu (aksen/AI). */
module.exports = {
  content: ['./src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        navy: { 700: '#1f3f6e', 800: '#13294b' },
        maroon: { 100: '#fde2e2', 700: '#7f1d1d' },
      },
    },
  },
};
