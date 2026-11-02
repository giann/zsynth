Texture2D<float4> Texture : register(t0, space2);
SamplerState Sampler : register(s0, space2);

cbuffer SharpenParams : register(b0, space3)
{
  float Strength;
  float2 TexelSize;
  float Padding;
};

float4 main(float2 TexCoord : TEXCOORD0) : SV_Target0
{
  const float4 source = Texture.Sample(Sampler, TexCoord);
  const float2 horizontal = float2(TexelSize.x, 0.0f);
  const float2 vertical = float2(0.0f, TexelSize.y);

  const float3 neighbors = (
    Texture.Sample(Sampler, TexCoord - horizontal).rgb +
    Texture.Sample(Sampler, TexCoord + horizontal).rgb +
    Texture.Sample(Sampler, TexCoord - vertical).rgb +
    Texture.Sample(Sampler, TexCoord + vertical).rgb
  ) * 0.25f;
  const float3 sharpened = source.rgb + (source.rgb - neighbors) * Strength;

  return float4(saturate(sharpened), source.a);
}
