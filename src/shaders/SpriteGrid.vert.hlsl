struct Sprite {
  // The sprite center and full dimensions, expressed in clip-space units.
  float2 Position;
  float2 Size;
  // The portion of the spritesheet to sample: (u_min, v_min, u_max, v_max).
  float4 UVRect;
  uint Foreground;
  uint Background;
};

// The CPU-side instance data is uploaded to a GPU storage buffer before drawing.
// SDL_shadercross maps this binding to the vertex-stage storage-buffer slot 0.
StructuredBuffer<Sprite> Instances : register(t0, space0);

struct Output {
  // Interpolated across the generated triangles and consumed by the fragment shader.
  float2 TexCoord : TEXCOORD0;
  // The final clip-space position consumed by the rasterizer.
  float4 Position : SV_Position;
  float4 Background : COLOR0;
  float4 Foreground : COLOR1;
};

float4 unpackColor(uint color) {
  return float4(
    ((color >> 24) & 0xff) / 255.0f,
    ((color >> 16) & 0xff) / 255.0f,
    ((color >> 8)  & 0xff) / 255.0f,
    ( color        & 0xff) / 255.0f
  );
}

// One sprite is rendered as two triangles. These are the four-corner indices
// that would normally live in an index buffer, but are generated here instead.
static const uint triangleIndices[6] = {0, 1, 2, 0, 2, 3};

// A unit quad centered at the origin. Position and Size transform these
// reusable local coordinates into each sprite's destination rectangle.
static const float2 corners[4] = {
  float2(-0.5f, -0.5f),
  float2( 0.5f, -0.5f),
  float2( 0.5f,  0.5f),
  float2(-0.5f,  0.5f)
};

// UV coordinates for the complete unit quad. The selected spritesheet
// rectangle is applied to these coordinates below.
static const float2 quadUVs[4] = {
  float2(0.0f, 1.0f),
  float2(1.0f, 1.0f),
  float2(1.0f, 0.0f),
  float2(0.0f, 0.0f)
};

// The draw call supplies six vertices per sprite. SV_VertexID therefore
// identifies both the sprite (which group of six) and its quad corner.
Output main(uint vertexIndex : SV_VertexID) {
  // Vertices 0..5 belong to sprite 0, 6..11 to sprite 1, and so on.
  const uint spriteIndex = vertexIndex / 6;

  // Select the corner used by this vertex in the current sprite's two triangles.
  const uint cornerIndex = triangleIndices[vertexIndex % 6];

  // Fetch the per-sprite destination rectangle and spritesheet rectangle.
  const Sprite sprite = Instances[spriteIndex];
  const float2 corner = corners[cornerIndex];
  const float2 uv = quadUVs[cornerIndex];

  Output output;

  // Scale and translate the unit quad into the sprite's clip-space rectangle.
  output.Position = float4(sprite.Position + corner * sprite.Size, 0.0f, 1.0f);

  // Remap the unit-quad UV into the selected rectangle of the spritesheet.
  output.TexCoord = lerp(sprite.UVRect.xy, sprite.UVRect.zw, uv);

  output.Foreground = unpackColor(sprite.Foreground);
  output.Background = unpackColor(sprite.Background);

  return output;
}
