Texture2D<float4> Texture : register(t0, space2);
SamplerState Sampler : register(s0, space2);

cbuffer BloomParams : register(b0, space3)
{
  float Threshold;
  float Intensity;
  float2 TexelSize;
  float2 Direction;
  uint2 Padding;
};

float4 main(float2 TexCoord : TEXCOORD0) : SV_Target0
{
  const float4 source = Texture.Sample(Sampler, TexCoord);
  // Palette colors are deliberately saturated, so use the brightest channel
  // instead of luminance to keep bright green and cyan details visible.
  const float brightness = max(source.r, max(source.g, source.b));
  const float weight = saturate((brightness - Threshold) / max(1.0f - Threshold, 0.0001f));

  return float4(source.rgb * weight, weight);
}
