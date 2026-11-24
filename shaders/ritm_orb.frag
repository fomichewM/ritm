#version 460 core
// «Ритм» — 3D-шар биовозраста v2 (ТЗ v3 §12, «как планета»).
// Сфера по нормали n = (x, y, sqrt(1 − d²)); текстура — 3D-fbm симплекс-шума
// ПО ВЕКТОРУ НОРМАЛИ, повёрнутому вокруг наклонённой оси (без UV-развёртки —
// нет швов на полюсах); второй слой «облаков» вращается в 1,35 раза быстрее
// (параллакс). Свет: Ламберт + мягкий блик Блинна + кромка Френеля цветом
// зоны + подсветка сзади снизу-справа; атмосфера за краем; «дыхание» ±2 %.
// Вращение задаётся снаружи (uRotation), чтобы «Уменьшение движения» давало
// статичный кадр (uRotation = 0,6, uTime = 0).
#include <flutter/runtime_effect.glsl>

uniform vec2 uResolution;
uniform float uTime;
uniform vec4 uColorA;   // цвет зоны
uniform vec4 uColorB;   // brandB
uniform float uRadius;  // радиус шара в долях половины стороны (0..1)
uniform float uIntensity;
uniform float uRotation; // угол поворота текстуры, рад

out vec4 fragColor;

// 3D симплекс-шум (Ashima Arts / Ian McEwan, MIT).
vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec4 mod289(vec4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec4 permute(vec4 x) { return mod289(((x * 34.0) + 10.0) * x); }
vec4 taylorInvSqrt(vec4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

float snoise(vec3 v) {
  const vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);
  const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);
  vec3 i = floor(v + dot(v, C.yyy));
  vec3 x0 = v - i + dot(i, C.xxx);
  vec3 g = step(x0.yzx, x0.xyz);
  vec3 l = 1.0 - g;
  vec3 i1 = min(g.xyz, l.zxy);
  vec3 i2 = max(g.xyz, l.zxy);
  vec3 x1 = x0 - i1 + C.xxx;
  vec3 x2 = x0 - i2 + C.yyy;
  vec3 x3 = x0 - D.yyy;
  i = mod289(i);
  vec4 p = permute(permute(permute(
            i.z + vec4(0.0, i1.z, i2.z, 1.0))
          + i.y + vec4(0.0, i1.y, i2.y, 1.0))
          + i.x + vec4(0.0, i1.x, i2.x, 1.0));
  float n_ = 0.142857142857;
  vec3 ns = n_ * D.wyz - D.xzx;
  vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
  vec4 x_ = floor(j * ns.z);
  vec4 y_ = floor(j - 7.0 * x_);
  vec4 x = x_ * ns.x + ns.yyyy;
  vec4 y = y_ * ns.x + ns.yyyy;
  vec4 h = 1.0 - abs(x) - abs(y);
  vec4 b0 = vec4(x.xy, y.xy);
  vec4 b1 = vec4(x.zw, y.zw);
  vec4 s0 = floor(b0) * 2.0 + 1.0;
  vec4 s1 = floor(b1) * 2.0 + 1.0;
  vec4 sh = -step(h, vec4(0.0));
  vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
  vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
  vec3 p0 = vec3(a0.xy, h.x);
  vec3 p1 = vec3(a0.zw, h.y);
  vec3 p2 = vec3(a1.xy, h.z);
  vec3 p3 = vec3(a1.zw, h.w);
  vec4 norm = taylorInvSqrt(vec4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
  p0 *= norm.x;
  p1 *= norm.y;
  p2 *= norm.z;
  p3 *= norm.w;
  vec4 m = max(0.5 - vec4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
  m = m * m;
  return 105.0 * dot(m * m, vec4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

float fbm4(vec3 p) {
  float s = 0.0;
  float a = 0.5;
  for (int i = 0; i < 4; i++) {
    s += a * snoise(p);
    p = p * 2.02 + vec3(1.7, 9.2, 3.1);
    a *= 0.5;
  }
  return 0.5 + 0.5 * s;
}

float fbm3(vec3 p) {
  float s = 0.0;
  float a = 0.5;
  for (int i = 0; i < 3; i++) {
    s += a * snoise(p);
    p = p * 2.07 + vec3(5.3, 1.1, 7.7);
    a *= 0.5;
  }
  return 0.5 + 0.5 * s;
}

// Поворот вокруг оси Y, наклонённой на 20° (как ось планеты).
vec3 spin(vec3 n, float a) {
  const float tc = 0.9396926; // cos 20°
  const float ts = 0.3420201; // sin 20°
  vec3 q = vec3(n.x, tc * n.y - ts * n.z, ts * n.y + tc * n.z);
  float c = cos(a);
  float s = sin(a);
  return vec3(c * q.x + s * q.z, q.y, -s * q.x + c * q.z);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 p = (frag - 0.5 * uResolution) / (0.5 * min(uResolution.x, uResolution.y));
  p.y = -p.y; // y вверх
  float r = uRadius * (1.0 + 0.02 * sin(uTime * 6.2831853 / 7.0));
  float d = length(p) / r;
  vec3 colA = uColorA.rgb;
  vec3 colB = uColorB.rgb;

  // Атмосфера за краем.
  if (d > 1.0) {
    float atm = smoothstep(1.08, 1.0, d) * 0.25 * uIntensity;
    if (atm <= 0.0) {
      fragColor = vec4(0.0);
      return;
    }
    fragColor = vec4(colA * atm, atm);
    return;
  }

  vec3 n = vec3(p / r, sqrt(max(0.0, 1.0 - d * d)));
  // Поверхность: 3D-fbm по повёрнутой нормали.
  vec3 q = spin(n, uRotation);
  float land = fbm4(q * 1.9);
  float vein = fbm3(q * 4.3 + 2.0);
  // Облака: быстрее (параллакс), реже.
  vec3 qc = spin(n, uRotation * 1.35 + 1.3);
  float cloud = smoothstep(0.52, 0.80, fbm3(qc * 2.6 + 7.0));

  vec3 L = normalize(vec3(-0.45, 0.55, 0.7));
  vec3 V = vec3(0.0, 0.0, 1.0);
  vec3 H = normalize(L + V);
  float lam = max(dot(n, L), 0.0);
  float spec = pow(max(dot(n, H), 0.0), 24.0) * 0.25;
  float fres = pow(1.0 - n.z, 2.2) * 0.8;
  vec2 nxy = n.xy + vec2(1e-4);
  float back = pow(1.0 - n.z, 3.0) * max(dot(normalize(nxy), normalize(vec2(0.7, -0.7))), 0.0) * 0.15;

  // Тёмный океан + светящиеся «материки» цвета зоны с прожилками brandB.
  vec3 base = mix(colA * 0.10, colA * 0.85, smoothstep(0.42, 0.78, land));
  base = mix(base, colB * 0.9, smoothstep(0.62, 0.9, vein) * 0.35);
  float shade = 0.16 + 0.84 * lam;
  vec3 col = base * shade;
  col = mix(col, vec3(0.92, 0.97, 0.95) * (0.25 + 0.75 * lam), cloud * 0.55);
  col += vec3(1.0) * spec;
  col += colA * fres;
  col += colB * back;
  // Тёмная ночная сторона — объём читается сильнее.
  col *= 0.75 + 0.25 * smoothstep(-0.2, 0.4, dot(n, L));

  // Мягкое затемнение под цифрой (центр диска) — текст читается на любой текстуре.
  col *= 1.0 - 0.32 * smoothstep(0.75, 0.0, d);

  float edge = smoothstep(1.0, 0.985, d); // сглаживание кромки
  float alpha = edge * uIntensity;
  fragColor = vec4(col * alpha, alpha);
}
