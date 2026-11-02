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
  const float2 step = Direction * TexelSize;
  float3 color = Texture.Sample(Sampler, TexCoord).rgb * 0.227027f;
  color += Texture.Sample(Sampler, TexCoord + step * 1.0f).rgb * 0.194595f;
  color += Texture.Sample(Sampler, TexCoord - step * 1.0f).rgb * 0.194595f;
  color += Texture.Sample(Sampler, TexCoord + step * 2.0f).rgb * 0.121622f;
  color += Texture.Sample(Sampler, TexCoord - step * 2.0f).rgb * 0.121622f;
  color += Texture.Sample(Sampler, TexCoord + step * 3.0f).rgb * 0.054054f;
  color += Texture.Sample(Sampler, TexCoord - step * 3.0f).rgb * 0.054054f;
  color += Texture.Sample(Sampler, TexCoord + step * 4.0f).rgb * 0.016216f;
  color += Texture.Sample(Sampler, TexCoord - step * 4.0f).rgb * 0.016216f;

  return float4(color, 1.0f);
}
