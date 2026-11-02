Texture2D<float4> Texture : register(t0, space2);
SamplerState Sampler : register(s0, space2);

cbuffer GrainParams : register(b0, space3)
{
  float Strength;
  uint FrameIndex;
  uint2 Padding;
};

// A small integer hash gives each pixel an independent value while the frame
// index makes the grain change discretely from frame to frame.
float hash(uint2 pixel, uint frameIndex)
{
  uint value = pixel.x * 1973u + pixel.y * 9277u + frameIndex * 26699u + 911u;
  value = (value ^ 61u) ^ (value >> 16u);
  value *= 9u;
  value = value ^ (value >> 4u);
  value *= 0x27d4eb2du;
  value = value ^ (value >> 15u);
  return float(value) / 4294967295.0f;
}

float4 main(float2 TexCoord : TEXCOORD0, float4 Position : SV_Position) : SV_Target0
{
  const float grain = hash(uint2(Position.xy), FrameIndex) * 2.0f - 1.0f;
  const float4 source = Texture.Sample(Sampler, TexCoord);
  // Scale the source instead of adding white noise. This keeps the grain
  // centered on the source luminance and avoids bright pixels accumulating a
  // white bias when the result is clamped.
  const float3 color = saturate(source.rgb * (1.0f + grain * Strength));
  return float4(color, source.a);
}
