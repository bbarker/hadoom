// http://xissburg.com/faster-gaussian-blur-in-glsl/
#version 130

varying vec2 v_texCoord;
varying vec2 v_blurTexCoords[4];

float pixel = 1.0f / 256;

void main()
{
    v_texCoord = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    // v_blurTexCoords[ 0] = v_texCoord + vec2(-0.028, 0.0);
    // v_blurTexCoords[ 1] = v_texCoord + vec2(-0.024, 0.0);
    // v_blurTexCoords[ 2] = v_texCoord + vec2(-0.020, 0.0);
    // v_blurTexCoords[ 3] = v_texCoord + vec2(-0.016, 0.0);
    // v_blurTexCoords[ 4] = v_texCoord + vec2(-0.012, 0.0);
    // v_blurTexCoords[ 5] = v_texCoord + vec2(-0.008, 0.0);
    v_blurTexCoords[ 0] = v_texCoord + vec2(-2 * pixel, 0.0);
    v_blurTexCoords[ 1] = v_texCoord + vec2(-1 * pixel, 0.0);
    v_blurTexCoords[ 2] = v_texCoord + vec2( 1 * pixel, 0.0);
    v_blurTexCoords[ 3] = v_texCoord + vec2( 2 * pixel, 0.0);
    // v_blurTexCoords[ 8] = v_texCoord + vec2( 0.008, 0.0);
    // v_blurTexCoords[ 9] = v_texCoord + vec2( 0.012, 0.0);
    // v_blurTexCoords[10] = v_texCoord + vec2( 0.016, 0.0);
    // v_blurTexCoords[11] = v_texCoord + vec2( 0.020, 0.0);
    // v_blurTexCoords[12] = v_texCoord + vec2( 0.024, 0.0);
    // v_blurTexCoords[13] = v_texCoord + vec2( 0.028, 0.0);
    gl_Position = vec4(v_texCoord * 2 - 1, 0.0f, 1.0f);
}
