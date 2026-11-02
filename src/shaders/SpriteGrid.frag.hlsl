Texture2D<float4> Texture : register(t0, space2);
SamplerState Sampler : register(s0, space2);

float4 main(float2 TexCoord : TEXCOORD0, float4 Background : COLOR0, float4 Foreground : COLOR1) : SV_Target0 {
  float4 texel = Texture.Sample(Sampler, TexCoord);
  float glyph = texel.a * texel.r;
  return lerp(Background, Foreground, glyph);
}
