uniform float softness;

void main() {
	float edge = max(softness, 0.001);
	float at = progress * (1.0 + edge);
	float t = smoothstep(at - edge, at, uv.x);
	color = vec4(mix(texture(new, uv).rgb, texture(old, uv).rgb, t), 1.0);
}
