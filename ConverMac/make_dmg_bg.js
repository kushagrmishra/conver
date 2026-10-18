const fs = require('fs');
const path = require('path');
const sharp = require('../conver/node_modules/sharp');

const width = 1320;
const height = 840;

const svg = `
<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <radialGradient id="bgGlow" cx="50%" cy="35%" r="65%">
      <stop offset="0%" stop-color="#232734" />
      <stop offset="50%" stop-color="#141720" />
      <stop offset="100%" stop-color="#0a0b10" />
    </radialGradient>

    <linearGradient id="arrowGrad" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="#38bdf8" stop-opacity="0.2" />
      <stop offset="35%" stop-color="#38bdf8" stop-opacity="0.9" />
      <stop offset="70%" stop-color="#818cf8" stop-opacity="0.95" />
      <stop offset="100%" stop-color="#c084fc" stop-opacity="1.0" />
    </linearGradient>

    <linearGradient id="ringGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.35" />
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0.06" />
    </linearGradient>

    <filter id="glow" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="8" result="blur" />
      <feComposite in="SourceGraphic" in2="blur" operator="over" />
    </filter>
  </defs>

  <!-- Background Canvas -->
  <rect width="${width}" height="${height}" fill="url(#bgGlow)" />

  <!-- Subtle Top Ambient Light -->
  <ellipse cx="660" cy="180" rx="480" ry="140" fill="#3b82f6" opacity="0.08" filter="url(#glow)" />

  <!-- Conver Title & Brand -->
  <text x="660" y="140" font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif" font-size="52" font-weight="800" fill="#ffffff" text-anchor="middle" letter-spacing="-0.5">Conver</text>
  
  <text x="660" y="195" font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif" font-size="25" font-weight="500" fill="rgba(255,255,255,0.65)" text-anchor="middle">Drag Conver into Applications to install</text>

  <!-- Left Platform Ring (Under Conver.app) -->
  <g transform="translate(340, 480)">
    <ellipse cx="0" cy="0" rx="146" ry="76" fill="rgba(255,255,255,0.03)" stroke="url(#ringGrad)" stroke-width="2.5" />
    <ellipse cx="0" cy="0" rx="114" ry="58" fill="rgba(56,189,248,0.06)" stroke="rgba(56,189,248,0.2)" stroke-width="1.5" />
  </g>

  <!-- Right Platform Ring (Under Applications) -->
  <g transform="translate(980, 480)">
    <ellipse cx="0" cy="0" rx="146" ry="76" fill="rgba(255,255,255,0.03)" stroke="url(#ringGrad)" stroke-width="2.5" />
    <ellipse cx="0" cy="0" rx="114" ry="58" fill="rgba(192,132,252,0.06)" stroke="rgba(192,132,252,0.2)" stroke-width="1.5" />
  </g>

  <!-- Glowing Arrow Track -->
  <g filter="url(#glow)">
    <path d="M 520 480 L 780 480" stroke="url(#arrowGrad)" stroke-width="7" stroke-linecap="round" stroke-dasharray="14 10" />
    <!-- Arrow Head -->
    <path d="M 764 456 L 804 480 L 764 504" fill="none" stroke="url(#arrowGrad)" stroke-width="7" stroke-linecap="round" stroke-linejoin="round" />
  </g>
  <path d="M 520 480 L 780 480" stroke="#ffffff" stroke-width="2.5" stroke-linecap="round" stroke-dasharray="14 10" opacity="0.8" />
  <path d="M 764 456 L 804 480 L 764 504" fill="none" stroke="#ffffff" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" opacity="0.9" />

  <!-- Bottom Tip Pill -->
  <rect x="470" y="720" width="380" height="46" rx="23" fill="rgba(255,255,255,0.07)" stroke="rgba(255,255,255,0.18)" stroke-width="1.5" />
  <text x="660" y="750" font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif" font-size="19" font-weight="600" fill="rgba(255,255,255,0.72)" text-anchor="middle">Press ⇧ + Z anytime to summon the Drop Wheel</text>
</svg>
`;

async function run() {
  const outPath = path.join(__dirname, 'dmg_background.png');
  await sharp(Buffer.from(svg))
    .png()
    .toFile(outPath);
  console.log('Generated DMG background at:', outPath);
}

run().catch(console.error);
