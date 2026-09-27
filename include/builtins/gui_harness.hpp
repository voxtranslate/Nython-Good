// include/builtins/gui_harness.hpp
//
// Test harness for the REAL SDL3 backend. The headless stub
// (thirdparty/sdl3-stub) lets tools/ide_driver.py drive the IDE by
// scripted input (NY_STUB_EVENTS) and read back what was drawn (a display
// list per presented frame). This header gives a real-SDL3 build the same
// two abilities, so the same end-to-end suite runs against real SDL3 -
// on its offscreen driver, or on a real X server / Xvfb:
//
//   - scripted input: the stub's command set (move, click, key, type,
//     wheel, resize, drop, focus, dialog, snap, quit, ...) is read from
//     NY_STUB_EVENTS (or NY_TEST_EVENTS) and delivered as real SDL_Event
//     values, with the same batching (one command per poll batch, then
//     NY_STUB_EVENT_GAP idle polls). `resize` really resizes the window.
//   - frame capture: every draw call gui.cpp makes is recorded at the SDL
//     call boundary (the same JSON-lines display list the stub writes),
//     and with NY_REAL_PIXELS=1 the rendered pixels of each presented
//     frame are read back, so `snap PATH` also writes PATH.png - a real
//     screenshot of real SDL3 rendering with real fonts.
//
// With neither variable set, every wrapper is a direct call to SDL (one
// predictable branch). gui.cpp includes this header only when it is built
// against a real SDL3 (NYTHON_SDL_STUB undefined); the names below are
// macros so the rest of gui.cpp is unchanged.
#pragma once
#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <SDL3_image/SDL_image.h>

namespace nyh {
bool active();                  // capture or scripted input is on
bool RenderClear(SDL_Renderer* r);
bool RenderPresent(SDL_Renderer* r);
bool RenderFillRect(SDL_Renderer* r, const SDL_FRect* rc);
bool RenderRect(SDL_Renderer* r, const SDL_FRect* rc);
bool RenderLine(SDL_Renderer* r, float x1, float y1, float x2, float y2);
bool RenderPoint(SDL_Renderer* r, float x, float y);
bool RenderTexture(SDL_Renderer* r, SDL_Texture* t, const SDL_FRect* src, const SDL_FRect* dst);
bool RenderGeometry(SDL_Renderer* r, SDL_Texture* t, const SDL_Vertex* v, int nv, const int* idx, int ni);
bool SetRenderClipRect(SDL_Renderer* r, const SDL_Rect* rc);
bool SetRenderViewport(SDL_Renderer* r, const SDL_Rect* rc);
bool SetRenderDrawColor(SDL_Renderer* r, Uint8 cr, Uint8 cg, Uint8 cb, Uint8 ca);
SDL_Renderer* CreateRenderer(SDL_Window* w, const char* name);
void DestroyRenderer(SDL_Renderer* r);
SDL_Window* CreateWin(const char* title, int w, int h, SDL_WindowFlags flags);
void DestroyWindow(SDL_Window* w);
SDL_Texture* CreateTextureFromSurface(SDL_Renderer* r, SDL_Surface* s);
void DestroyTexture(SDL_Texture* t);
void DestroySurface(SDL_Surface* s);
TTF_Font* OpenFont(const char* file, float ptsize);
void SetFontStyle(TTF_Font* f, TTF_FontStyleFlags style);
SDL_Surface* RenderText_Blended(TTF_Font* f, const char* text, size_t len, SDL_Color fg);
bool PollEvent(SDL_Event* e);
bool WaitEventTimeout(SDL_Event* e, Sint32 ms);
bool PushEvent(SDL_Event* e);
SDL_Keymod GetModState(void);
bool SetClipboardText(const char* text);
char* GetClipboardText(void);
bool ShowSimpleMessageBox(SDL_MessageBoxFlags flags, const char* title, const char* msg, SDL_Window* w);
void ShowOpenFileDialog(SDL_DialogFileCallback cb, void* ud, SDL_Window* w,
                        const SDL_DialogFileFilter* f, int nf, const char* def, bool many);
void ShowSaveFileDialog(SDL_DialogFileCallback cb, void* ud, SDL_Window* w,
                        const SDL_DialogFileFilter* f, int nf, const char* def);
void ShowOpenFolderDialog(SDL_DialogFileCallback cb, void* ud, SDL_Window* w, const char* def, bool many);
}  // namespace nyh

#ifndef NYH_IMPLEMENTATION
#define SDL_RenderClear            nyh::RenderClear
#define SDL_RenderPresent          nyh::RenderPresent
#define SDL_RenderFillRect         nyh::RenderFillRect
#define SDL_RenderRect             nyh::RenderRect
#define SDL_RenderLine             nyh::RenderLine
#define SDL_RenderPoint            nyh::RenderPoint
#define SDL_RenderTexture          nyh::RenderTexture
#define SDL_RenderGeometry         nyh::RenderGeometry
#define SDL_SetRenderClipRect      nyh::SetRenderClipRect
#define SDL_SetRenderViewport      nyh::SetRenderViewport
#define SDL_SetRenderDrawColor     nyh::SetRenderDrawColor
#define SDL_CreateRenderer         nyh::CreateRenderer
#define SDL_DestroyRenderer        nyh::DestroyRenderer
#define SDL_CreateWindow           nyh::CreateWin
#define SDL_DestroyWindow          nyh::DestroyWindow
#define SDL_CreateTextureFromSurface nyh::CreateTextureFromSurface
#define SDL_DestroyTexture         nyh::DestroyTexture
#define SDL_DestroySurface         nyh::DestroySurface
#define TTF_OpenFont               nyh::OpenFont
#define TTF_SetFontStyle           nyh::SetFontStyle
#define TTF_RenderText_Blended     nyh::RenderText_Blended
#define SDL_PollEvent              nyh::PollEvent
#define SDL_WaitEventTimeout       nyh::WaitEventTimeout
#define SDL_PushEvent              nyh::PushEvent
#define SDL_GetModState            nyh::GetModState
#define SDL_SetClipboardText       nyh::SetClipboardText
#define SDL_GetClipboardText       nyh::GetClipboardText
#define SDL_ShowSimpleMessageBox   nyh::ShowSimpleMessageBox
#define SDL_ShowOpenFileDialog     nyh::ShowOpenFileDialog
#define SDL_ShowSaveFileDialog     nyh::ShowSaveFileDialog
#define SDL_ShowOpenFolderDialog   nyh::ShowOpenFolderDialog
#endif
