const fs = require('fs');
const path = require('path');
const sharp = require('../conver/node_modules/sharp');

// Exact 1x point dimensions for macOS Finder window (660 x 440 points)
const width = 660;
const height = 440;

const svg = `
<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <radialGradient id="bgGlow" cx="50%" cy="30%" r="70%">
      <stop offset="0%" stop-color="#242838" />
      <stop offset="55%" stop-color="#131620" />
      <stop offset="100%" stop-color="#090a0f" />
    </radialGradient>

    <linearGradient id="arrowGrad" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="#38bdf8" stop-opacity="0.25" />
      <stop offset="40%" stop-color="#38bdf8" stop-opacity="0.95" />
      <stop offset="75%" stop-color="#818cf8" stop-opacity="1.0" />
      <stop offset="100%" stop-color="#c084fc" stop-opacity="1.0" />
    </linearGradient>

    <linearGradient id="ringGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.38" />
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0.06" />
    </linearGradient>

    <filter id="glow" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="5" result="blur" />
      <feComposite in="SourceGraphic" in2="blur" operator="over" />
    </filter>
  </defs>

  <!-- Seamless Canvas Background -->
  <rect width="${width}" height="${height}" fill="url(#bgGlow)" />

  <!-- Top Ambient Glow -->
  <ellipse cx="330" cy="80" rx="280" ry="70" fill="#3b82f6" opacity="0.10" filter="url(#glow)" />

  <!-- Title & Instructions (Comfortably Above Icons) -->
  <text x="330" y="58" font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif" font-size="28" font-weight="800" fill="#ffffff" text-anchor="middle" letter-spacing="-0.4">Conver</text>
  
  <text x="330" y="86" font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif" font-size="13.5" font-weight="500" fill="rgba(255,255,255,0.70)" text-anchor="middle">Drag Conver into Applications to install</text>

  <!-- Left Platform Pedestal (Exactly under Conver.app at {180, 230}) -->
  <g transform="translate(180, 230)">
    <ellipse cx="0" cy="18" rx="76" ry="38" fill="rgba(255,255,255,0.03)" stroke="url(#ringGrad)" stroke-width="1.8" />
    <ellipse cx="0" cy="18" rx="58" ry="28" fill="rgba(56,189,248,0.06)" stroke="rgba(56,189,248,0.25)" stroke-width="1.2" />
  </g>

  <!-- Right Platform Pedestal (Exactly under Applications at {480, 230}) -->
  <g transform="translate(480, 230)">
    <ellipse cx="0" cy="18" rx="76" ry="38" fill="rgba(255,255,255,0.03)" stroke="url(#ringGrad)" stroke-width="1.8" />
    <ellipse cx="0" cy="18" rx="58" ry="28" fill="rgba(192,132,252,0.06)" stroke="rgba(192,132,252,0.25)" stroke-width="1.2" />
  </g>

  <!-- Glowing Arrow (Connecting {180, 230} to {480, 230}) -->
  <g filter="url(#glow)">
    <path d="M 272 230 L 388 230" stroke="url(#arrowGrad)" stroke-width="4.5" stroke-linecap="round" stroke-dasharray="8 6" />
    <path d="M 378 216 L 398 230 L 378 244" fill="none" stroke="url(#arrowGrad)" stroke-width="4.5" stroke-linecap="round" stroke-linejoin="round" />
  </g>
  <path d="M 272 230 L 388 230" stroke="#ffffff" stroke-width="1.8" stroke-linecap="round" stroke-dasharray="8 6" opacity="0.85" />
  <path d="M 378 216 L 398 230 L 378 244" fill="none" stroke="#ffffff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" opacity="0.95" />

  <!-- Bottom Tip Pill (Comfortably Below Icons) -->
  <rect x="200" y="380" width="260" height="28" rx="14" fill="rgba(255,255,255,0.06)" stroke="rgba(255,255,255,0.16)" stroke-width="1" />
  <text x="330" y="398" font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif" font-size="11" font-weight="600" fill="rgba(255,255,255,0.72)" text-anchor="middle">Press ⇧ + Z anytime for Drop Wheel</text>
</svg>
`;

async function run() {
  const outPath = path.join(__dirname, 'dmg_background.png');
  await sharp(Buffer.from(svg))
    .png()
    .toFile(outPath);
  console.log(`Generated DMG background (${width}x${height}) at:`, outPath);
}

run().catch(console.error);
