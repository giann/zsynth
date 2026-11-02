Texture2D<float4> Scene : register(t0, space2);
Texture2D<float4> Bloom : register(t1, space2);
SamplerState SceneSampler : register(s0, space2);
SamplerState BloomSampler : register(s1, space2);

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
  const float4 scene = Scene.Sample(SceneSampler, TexCoord);
  const float3 bloom = Bloom.Sample(BloomSampler, TexCoord).rgb;

  return float4(saturate(scene.rgb + bloom * Intensity), scene.a);
}
