struct Output {
  // Coordinates used to sample the complete source texture.
  float2 TexCoord : TEXCOORD0;
  // The fullscreen quad position consumed by the rasterizer.
  float4 Position : SV_Position;
};

// The composite pass generates its fullscreen quad procedurally.
static const uint triangleIndices[6] = {0, 1, 2, 0, 2, 3};

static const float2 corners[4] = {
  float2(-1.0f, -1.0f),
  float2( 1.0f, -1.0f),
  float2( 1.0f,  1.0f),
  float2(-1.0f,  1.0f)
};

static const float2 quadUVs[4] = {
  float2(0.0f, 1.0f),
  float2(1.0f, 1.0f),
  float2(1.0f, 0.0f),
  float2(0.0f, 0.0f)
};

Output main(uint vertexIndex : SV_VertexID) {
  const uint cornerIndex = triangleIndices[vertexIndex % 6];

  Output output;
  output.Position = float4(corners[cornerIndex], 0.0f, 1.0f);
  output.TexCoord = quadUVs[cornerIndex];
  return output;
}
