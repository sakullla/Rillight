#include "../../core/windows_color_pipeline.h"

#include "../color_pipeline_fixtures.h"
#include "../../core/portable_color_pipeline.h"
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <cstring>

std::vector<uint8_t> TexturePixels(ID3D11Texture2D* texture) {
  using Microsoft::WRL::ComPtr;
  ComPtr<ID3D11Device> device; texture->GetDevice(&device);
  ComPtr<ID3D11DeviceContext> context; device->GetImmediateContext(&context);
  D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
  const int width = desc.Width, height = desc.Height;
  desc.BindFlags = desc.MiscFlags = 0; desc.Usage = D3D11_USAGE_STAGING;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ComPtr<ID3D11Texture2D> staging;
  assert(SUCCEEDED(device->CreateTexture2D(&desc, nullptr, &staging)));
  context->CopyResource(staging.Get(), texture);
  D3D11_MAPPED_SUBRESOURCE mapped{};
  assert(SUCCEEDED(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped)));
  std::vector<uint8_t> pixels(width*height*4);
  for (int y=0;y<height;++y)
    std::memcpy(pixels.data()+y*width*4,static_cast<const uint8_t*>(mapped.pData)+y*mapped.RowPitch,width*4);
  context->Unmap(staging.Get(),0);
  return pixels;
}

float HalfFloat(uint16_t value) {
  const int exponent = (value >> 10) & 31;
  const int mantissa = value & 1023;
  const float result = exponent == 0 ? std::ldexp(static_cast<float>(mantissa), -24) :
      std::ldexp(1.0f + static_cast<float>(mantissa) / 1024.0f, exponent - 15);
  assert(exponent != 31);
  return value & 0x8000 ? -result : result;
}

std::vector<float> MappedLinearPixels(ID3D11Device* device, ID3D11DeviceContext* context,
                                    ID3D11Texture2D* texture) {
  using Microsoft::WRL::ComPtr;
  D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
  assert(desc.Format == DXGI_FORMAT_R16G16B16A16_FLOAT);
  const int width = desc.Width, height = desc.Height;
  desc.BindFlags = desc.MiscFlags = 0; desc.Usage = D3D11_USAGE_STAGING;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ComPtr<ID3D11Texture2D> staging;
  assert(SUCCEEDED(device->CreateTexture2D(&desc, nullptr, &staging)));
  context->CopyResource(staging.Get(), texture);
  D3D11_MAPPED_SUBRESOURCE mapped{};
  assert(SUCCEEDED(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped)));
  std::vector<float> pixels(static_cast<size_t>(width) * height * 4);
  for (int y = 0; y < height; ++y) {
    const auto* row = reinterpret_cast<const uint16_t*>(static_cast<const uint8_t*>(mapped.pData) + y * mapped.RowPitch);
    for (int x = 0; x < width * 4; ++x) pixels[static_cast<size_t>(y) * width * 4 + x] = HalfFloat(row[x]);
  }
  context->Unmap(staging.Get(), 0);
  return pixels;
}

std::vector<float> TextureLinearPixels(ID3D11Texture2D* texture) {
  using Microsoft::WRL::ComPtr;
  ComPtr<ID3D11Device> device; texture->GetDevice(&device);
  ComPtr<ID3D11DeviceContext> context; device->GetImmediateContext(&context);
  return MappedLinearPixels(device.Get(), context.Get(), texture);
}

// Read through a second device before any producer Map. A same-device Map
// would hide a missing flush, and this path is what the HDR host uses.
std::vector<float> SharedTextureLinearPixels(ID3D11Texture2D* texture) {
  using Microsoft::WRL::ComPtr;
  D3D11_TEXTURE2D_DESC produced{}; texture->GetDesc(&produced);
  assert(produced.Format == DXGI_FORMAT_R16G16B16A16_FLOAT);
  assert((produced.MiscFlags & D3D11_RESOURCE_MISC_SHARED) != 0);
  assert((produced.MiscFlags & D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX) == 0);
  ComPtr<IDXGIResource> resource;
  assert(SUCCEEDED(texture->QueryInterface(IID_PPV_ARGS(&resource))));
  HANDLE handle = nullptr;
  assert(SUCCEEDED(resource->GetSharedHandle(&handle)) && handle);
  const D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  assert(SUCCEEDED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
      &level, 1, D3D11_SDK_VERSION, &device, nullptr, &context)));
  ComPtr<ID3D11Texture2D> imported;
  assert(SUCCEEDED(device->OpenSharedResource(handle, IID_PPV_ARGS(&imported))));
  return MappedLinearPixels(device.Get(), context.Get(), imported.Get());
}

double PqNits(double code) {
  const double p = std::pow(code, 1.0 / 78.84375);
  return 10000 * std::pow(std::max(p - .8359375, 0.0) /
      (18.8515625 - 18.6875 * p), 1.0 / .1593017578125);
}

void CheckNativeHdr() {
  WindowsColorPipeline pipeline;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> retained;
  std::vector<float> retained_pixels;
  for (const int code : {64, 512, 723, 800, 940}) {
    AVFrame* source = Picture(AV_PIX_FMT_YUV420P10LE, static_cast<uint16_t>(code));
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    texture.Attach(static_cast<ID3D11Texture2D*>(pipeline.RenderScRgbTexture(source, 32, 24, false)));
    assert(texture);
    const auto pixels = TextureLinearPixels(texture.Get());
    const double expected = PqNits((code - 64) / 876.0) / 80.0;
    for (size_t i = 0; i < pixels.size(); i += 4) {
      for (size_t c = 0; c < 3; ++c)
        assert(std::abs(pixels[i + c] - expected) < std::max(.003, expected * .003));
      assert(pixels[i + 3] == 1);
    }
    if (code == 723) { assert(pixels[0] > 12); retained = texture; retained_pixels = pixels; }
    if (retained) assert(TextureLinearPixels(retained.Get()) == retained_pixels);
    // Switching between native FP16 and SDR must preserve both allocation
    // ownership and the original, separately tested SDR output policy.
    std::vector<uint8_t> sdr(32 * 24 * 4);
    assert(pipeline.Render(source, 32, 24, false, sdr.data(), 32 * 4));
    if (retained) assert(TextureLinearPixels(retained.Get()) == retained_pixels);
    assert(!pipeline.RenderScRgbTexture(source, 32, 24, false, -1));
    av_frame_free(&source);
  }
  // Wide-gamut red requires a signed green/blue component in scRGB. An
  // accidental [0,1] clamp would discard the BT.2020 gamut extension.
  AVFrame* source = Picture(AV_PIX_FMT_YUV420P10LE, 512);
  for (int y = 0; y < source->height / 2; ++y) {
    std::fill_n(reinterpret_cast<uint16_t*>(source->data[1] + y * source->linesize[1]), source->width / 2, uint16_t{350});
    std::fill_n(reinterpret_cast<uint16_t*>(source->data[2] + y * source->linesize[2]), source->width / 2, uint16_t{780});
  }
  Microsoft::WRL::ComPtr<ID3D11Texture2D> gamut;
  gamut.Attach(static_cast<ID3D11Texture2D*>(pipeline.RenderScRgbTexture(source, 32, 24, false)));
  assert(gamut);
  const auto pixels = TextureLinearPixels(gamut.Get());
  assert(pixels[0] > 1 && pixels[1] < 0 && pixels[2] < 0);
  av_frame_free(&source);

  source = Picture(AV_PIX_FMT_YUV420P10LE, 800);
  Metadata(source);
  for (int plane = 1; plane <= 2; ++plane)
    for (int y = 0; y < source->height / 2; ++y)
      std::fill_n(reinterpret_cast<uint16_t*>(source->data[plane] + y * source->linesize[plane]), source->width / 2, uint16_t{800});
  gamut.Reset();
  gamut.Attach(static_cast<ID3D11Texture2D*>(pipeline.RenderScRgbTexture(source, 24, 32, true)));
  assert(gamut);
  const auto dovi = TextureLinearPixels(gamut.Get());
  const double expected = PqNits(800.0 / 1023) / 80;
  for (size_t i = 0; i < dovi.size(); i += 4)
    for (size_t c = 0; c < 3; ++c) assert(std::abs(dovi[i+c] - expected) < expected * .005);
  assert(dovi[0] > 1);
  av_frame_free(&source);
}

void CheckFelStaysScRgb() {
  WindowsColorPipeline windows;
  PortableColorPipeline portable;
  AVFrame* base = Picture(AV_PIX_FMT_YUV420P10LE, 64);
  auto* metadata = Metadata(base);
  auto* header = av_dovi_get_header(metadata);
  header->coef_log2_denom = 10;
  header->el_bit_depth = 10;
  auto* mapping = av_dovi_get_mapping(metadata);
  for (int channel = 0; channel < 3; ++channel) {
    auto& curve = mapping->curves[channel];
    curve.poly_order[0] = 1;
    curve.poly_coef[0][0] = 256;
    curve.poly_coef[0][1] = 512;
    curve.poly_coef[0][2] = 0;
  }
  AVFrame* layer = Picture(AV_PIX_FMT_YUV420P10LE, 800);
  constexpr int width = 32;
  constexpr int height = 24;
  std::vector<uint16_t> base_half(static_cast<size_t>(width) * height * 4);
  std::vector<uint16_t> fel_half(base_half.size());
  header->disable_residual_flag = 1;
  assert(portable.RenderLinearHalf(base, width, height, true, base_half.data(), width * 8));
  header->disable_residual_flag = 0;
  assert(portable.RenderLinearHalf(base, width, height, true, fel_half.data(), width * 8, layer));
  assert(base_half != fel_half);
  Microsoft::WRL::ComPtr<ID3D11Texture2D> base_texture;
  base_texture.Attach(static_cast<ID3D11Texture2D*>(
      windows.UploadScRgbHalf(base_half.data(), width, height, width * 8)));
  Microsoft::WRL::ComPtr<ID3D11Texture2D> fel_texture;
  fel_texture.Attach(static_cast<ID3D11Texture2D*>(
      windows.UploadScRgbHalf(fel_half.data(), width, height, width * 8)));
  assert(base_texture && fel_texture);
  D3D11_TEXTURE2D_DESC desc{};
  fel_texture->GetDesc(&desc);
  assert(desc.Format == DXGI_FORMAT_R16G16B16A16_FLOAT);
  const auto base_shared = SharedTextureLinearPixels(base_texture.Get());
  const auto fel_shared = SharedTextureLinearPixels(fel_texture.Get());
  const auto base_pixels = TextureLinearPixels(base_texture.Get());
  const auto fel_pixels = TextureLinearPixels(fel_texture.Get());
  assert(base_shared == base_pixels);
  assert(fel_shared == fel_pixels);
  bool differed = false;
  for (size_t i = 0; i < fel_pixels.size() && i < base_pixels.size(); ++i)
    if (std::fabs(fel_pixels[i] - base_pixels[i]) > 0.001f) differed = true;
  assert(differed);
  av_frame_free(&layer);
  av_frame_free(&base);
}

int main() {
  CheckNativeHdr();
  CheckFelStaysScRgb();
  // GPU output must work before any CPU render, retain old images across
  // consecutive dispatches/resizes and still allow CPU readback afterwards.
  {
    WindowsColorPipeline gpu_first;
    std::vector<Microsoft::WRL::ComPtr<ID3D11Texture2D>> retained;
    std::vector<std::vector<uint8_t>> expected;
    for (int index = 0; index < 12; ++index) {
      const int width = index % 2 ? 24 : 32;
      const int height = index % 2 ? 32 : 24;
      AVFrame* source = Picture(AV_PIX_FMT_YUV420P10LE, 64 + index * 64);
      Microsoft::WRL::ComPtr<ID3D11Texture2D> image;
      image.Attach(static_cast<ID3D11Texture2D*>(
          gpu_first.RenderTexture(source, width, height, false)));
      assert(image);
      const auto actual = TexturePixels(image.Get());
      std::vector<uint8_t> readback(width * height * 4);
      assert(gpu_first.Render(source, width, height, false,
                              readback.data(), width * 4));
      assert(actual == readback);
      expected.push_back(actual);
      retained.push_back(std::move(image));
      for (size_t held = 0; held < retained.size(); ++held)
        assert(TexturePixels(retained[held].Get()) == expected[held]);
      av_frame_free(&source);
    }
  }
  WindowsColorPipeline pipeline;
  PortableColorPipeline portable;
  std::vector<uint8_t> pixels(32 * 24 * 4);
  auto checkPortable = [&](const AVFrame* frame, bool dovi) {
    std::vector<uint8_t> reference(pixels.size());
    assert(portable.Render(frame, 32, 24, dovi, reference.data(), 32 * 4));
    for (size_t i = 0; i < pixels.size(); ++i)
      assert(std::abs(static_cast<int>(pixels[i]) - reference[i]) <= 2);
  };
  AVFrame* hdr = Picture(AV_PIX_FMT_YUV420P10LE, 64);
  assert(pipeline.Render(hdr, 32, 24, false, pixels.data(), 32 * 4));
  Gray(pixels, 0, 1);  // limited-range HDR10 black
  Microsoft::WRL::ComPtr<ID3D11Texture2D> held;
  held.Attach(static_cast<ID3D11Texture2D*>(pipeline.RenderTexture(hdr,32,24,false)));
  assert(held && TexturePixels(held.Get()) == pixels);
  checkPortable(hdr, false);
  av_frame_free(&hdr);
  hdr = Picture(AV_PIX_FMT_YUV420P10LE, 512);
  assert(pipeline.Render(hdr, 32, 24, false, pixels.data(), 32 * 4));
  Gray(pixels, 100, 200);
  assert(TexturePixels(held.Get()) != pixels); // immutable across subsequent conversion
  Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
  texture.Attach(static_cast<ID3D11Texture2D*>(pipeline.RenderTexture(hdr,32,24,false)));
  assert(texture && TexturePixels(texture.Get()) == pixels);
  checkPortable(hdr, false);
  av_frame_free(&hdr);

  AVFrame* dovi = Picture(AV_PIX_FMT_YUV420P10LE, 512);
  auto* metadata = Metadata(dovi);
  assert(pipeline.Render(dovi, 32, 24, true, pixels.data(), 32 * 4));
  Gray(pixels, 100, 200);
  const auto polynomial = pixels;
  texture.Reset();
  texture.Attach(static_cast<ID3D11Texture2D*>(pipeline.RenderTexture(dovi,32,24,true)));
  assert(texture && TexturePixels(texture.Get()) == pixels);
  checkPortable(dovi, true);
  auto* mapping = av_dovi_get_mapping(metadata);
  for (int c = 0; c < 3; ++c) {
    auto& curve = mapping->curves[c];
    curve.mapping_idc[0] = AV_DOVI_MAPPING_MMR;
    curve.mmr_order[0] = 1;
    curve.mmr_coef[0][0][c] = 1;
  }
  assert(pipeline.Render(dovi, 32, 24, true, pixels.data(), 32 * 4));
  assert(pixels == polynomial);
  checkPortable(dovi, true);
  auto* color = av_dovi_get_color(metadata);
  color->ycc_to_rgb_matrix[0].den = 0;
  assert(!pipeline.Render(dovi, 32, 24, true, pixels.data(), 32 * 4));
  color->ycc_to_rgb_matrix[0].den = 1;
  mapping->curves[0].num_pivots = 10;
  assert(!pipeline.Render(dovi, 32, 24, true, pixels.data(), 32 * 4));
  av_frame_free(&dovi);

  dovi = Picture(AV_PIX_FMT_P010LE, 512);
  Metadata(dovi);
  assert(pipeline.Render(dovi, 32, 24, true, pixels.data(), 32 * 4));
  assert(pixels == polynomial);  // 10-bit planar and MSB-packed P010 agree
  checkPortable(dovi, true);
  av_frame_free(&dovi);

  // LUT interpolation must match the analytic PQ/sRGB reference through the
  // complete GPU shader, including near-black codes and highlight clipping.
  for (int code = 0; code <= 1023; code += 17) {
    dovi = Picture(AV_PIX_FMT_YUV420P10LE, static_cast<uint16_t>(code));
    Metadata(dovi);
    for (int plane = 1; plane <= 2; ++plane) {
      for (int y = 0; y < dovi->height / 2; ++y)
        std::fill_n(reinterpret_cast<uint16_t*>(dovi->data[plane] + y * dovi->linesize[plane]),
                    dovi->width / 2, static_cast<uint16_t>(code));
    }
    assert(pipeline.Render(dovi, 32, 24, true, pixels.data(), 32 * 4));
    const int reference = ReferenceGray(code);
    Gray(pixels, std::max(0, reference - 1), std::min(255, reference + 1));
    av_frame_free(&dovi);
  }

  for (const auto format : {AV_PIX_FMT_YUV420P12LE, AV_PIX_FMT_P012LE,
                            AV_PIX_FMT_YUV420P16LE, AV_PIX_FMT_P016LE}) {
    const int depth = av_pix_fmt_desc_get(format)->comp[0].depth;
    dovi = Picture(format, static_cast<uint16_t>(1u << (depth - 1)));
    metadata = Metadata(dovi);
    assert(pipeline.Render(dovi, 32, 24, true, pixels.data(), 32 * 4));
    Gray(pixels, 100, 200);
    for (size_t i = 0; i < pixels.size(); ++i)
      assert(std::abs(static_cast<int>(pixels[i]) - polynomial[i]) <= 1);
    av_dovi_get_color(metadata)->source_max_pq = 4096;
    assert(!pipeline.Render(dovi, 32, 24, true, pixels.data(), 32 * 4));
    av_frame_free(&dovi);
    hdr = Picture(format, static_cast<uint16_t>(16u << (depth - 8)));
    assert(pipeline.Render(hdr, 32, 24, false, pixels.data(), 32 * 4));
    Gray(pixels, 0, 1);
    av_frame_free(&hdr);
  }
}
