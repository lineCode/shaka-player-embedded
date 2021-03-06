// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "shaka/ShakaPlayerView.h"

#include "shaka/utils.h"
#include "src/public/ShakaPlayer+Internal.h"

#define ShakaRenderLoopDelay (1.0 / 60)

@interface ShakaPlayerView () {
  NSTimer *_renderLoopTimer;
  NSTimer *_textLoopTimer;
  CALayer *_imageLayer;
  CALayer *_textLayer;
  CALayer *_avPlayerLayer;
  ShakaPlayer *_player;
  shaka::media::VideoFillMode _gravity;

  NSMutableDictionary<NSValue *, NSSet<CALayer *> *> *_cues;
}

@end

@implementation ShakaPlayerView

// MARK: setup

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    [self setup];
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  if ((self = [super initWithCoder:coder])) {
    [self setup];
  }
  return self;
}

- (instancetype)initWithPlayer:(ShakaPlayer *)player {
  if ((self = [super init])) {
    [self setup];
    [self setPlayer:player];
  }
  return self;
}

- (void)dealloc {
  [_renderLoopTimer invalidate];
  [_textLoopTimer invalidate];
}

- (void)setup {
  // Start up the render loop.  Use a block with a capture to a weak variable to ensure that the
  // view will be destroyed once there are no other references.
  __weak ShakaPlayerView *weakSelf = self;
  _renderLoopTimer = [NSTimer scheduledTimerWithTimeInterval:ShakaRenderLoopDelay
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
                                                         [weakSelf renderLoop];
                                                       }];
  _textLoopTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                   repeats:YES
                                                     block:^(NSTimer *timer) {
                                                       [weakSelf textLoop];
                                                     }];


  // Set up the image layer.
  _imageLayer = [CALayer layer];
  [self.layer addSublayer:_imageLayer];

  // Set up the text layer.
  _textLayer = [CALayer layer];
  [self.layer addSublayer:_textLayer];

  // Disable default animations.
  _imageLayer.actions = @{@"position": [NSNull null], @"bounds": [NSNull null]};

  _gravity = shaka::media::VideoFillMode::MaintainRatio;
  _cues = [[NSMutableDictionary alloc] init];
}

- (ShakaPlayer *)player {
  return _player;
}

- (void)setPlayer:(ShakaPlayer *)player {
  if (_avPlayerLayer) {
    [_avPlayerLayer removeFromSuperlayer];
    _avPlayerLayer = nil;
  }

  _player = player;
  if (_player) {
    _player.mediaPlayer->SetVideoFillMode(_gravity);

    _avPlayerLayer = static_cast<CALayer *>(CFBridgingRelease(player.mediaPlayer->GetIosView()));
    [self.layer addSublayer:_avPlayerLayer];
  }
}

- (void)setVideoGravity:(AVLayerVideoGravity)videoGravity {
  if (videoGravity == AVLayerVideoGravityResize) {
    _gravity = shaka::media::VideoFillMode::Stretch;
  } else if (videoGravity == AVLayerVideoGravityResizeAspectFill) {
    _gravity = shaka::media::VideoFillMode::Zoom;
  } else if (videoGravity == AVLayerVideoGravityResizeAspect) {
    _gravity = shaka::media::VideoFillMode::MaintainRatio;
  } else {
    [NSException raise:NSGenericException format:@"Invalid value for videoGravity"];
  }
  if (_player)
    _player.mediaPlayer->SetVideoFillMode(_gravity);
}

// MARK: rendering

- (void)renderLoop {
  if (!_player) {
    self->_imageLayer.contents = nil;
    return;
  }

  if (CGImageRef image = _player.videoRenderer->Render()) {
    _imageLayer.contents = (__bridge_transfer id)image;

    // Fit image in frame.
    shaka::ShakaRect image_bounds = {0, 0, CGImageGetWidth(image), CGImageGetHeight(image)};
    shaka::ShakaRect dest_bounds = {
        0,
        0,
        static_cast<int>(self.bounds.size.width),
        static_cast<int>(self.bounds.size.height),
    };
    shaka::ShakaRect src;
    shaka::ShakaRect dest;
    shaka::FitVideoToRegion(image_bounds, dest_bounds, _player.videoRenderer->fill_mode(), &src,
                            &dest);
    _imageLayer.contentsRect = CGRectMake(
        static_cast<CGFloat>(src.x) / image_bounds.w, static_cast<CGFloat>(src.y) / image_bounds.h,
        static_cast<CGFloat>(src.w) / image_bounds.w, static_cast<CGFloat>(src.h) / image_bounds.h);
    _imageLayer.frame = CGRectMake(dest.x, dest.y, dest.w, dest.h);
  }
}

- (void)layoutSubviews {
  [super layoutSubviews];
  if (_avPlayerLayer)
    _avPlayerLayer.frame = self.bounds;
}

- (void)textLoop {
  if (_player && _player.closedCaptions) {
    BOOL sizeChanged = _textLayer.frame.size.width != _imageLayer.frame.size.width ||
                       _textLayer.frame.size.height != _imageLayer.frame.size.height;

    _textLayer.hidden = NO;
    _textLayer.frame = _imageLayer.frame;

    [self remakeTextCues:sizeChanged];
  } else {
    _textLayer.hidden = YES;
  }
}

- (void)remakeTextCues:(BOOL)sizeChanged {
  if (!_player)
    return;

  auto text_tracks = _player.mediaPlayer->TextTracks();
  auto activeCues = text_tracks[0]->active_cues(_player.currentTime);

  if (sizeChanged) {
    for (CALayer *layer in [_textLayer.sublayers copy])
      [layer removeFromSuperlayer];
    [_cues removeAllObjects];
  }

  // Use the system font for body. The ensures that if the user changes their font size, it will use
  // that font size.
  UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];

  // Add layers for new cues.
  for (unsigned long i = 0; i < activeCues.size(); i++) {
    // Read the cues in inverse order, so the oldest cue is at the bottom.
    std::shared_ptr<shaka::media::VTTCue> cue = activeCues[activeCues.size() - i - 1];
    if (_cues[[NSValue valueWithPointer:cue.get()]] != nil)
      continue;

    NSString *cueText = [NSString stringWithUTF8String:cue->text().c_str()];
    NSMutableSet<CALayer *> *layers = [[NSMutableSet alloc] init];
    for (NSString *line in [cueText componentsSeparatedByString:@"\n"]) {
      CATextLayer *cueLayer = [[CATextLayer alloc] init];
      cueLayer.string = line;
      cueLayer.font = CGFontCreateWithFontName(static_cast<CFStringRef>(font.fontName));
      cueLayer.fontSize = font.pointSize;
      cueLayer.backgroundColor = [UIColor blackColor].CGColor;
      cueLayer.foregroundColor = [UIColor whiteColor].CGColor;
      cueLayer.alignmentMode = kCAAlignmentCenter;

      // TODO: Take into account direction setting, snap to lines, position align, etc.

      // Determine size of cue line.
      CGFloat width = static_cast<CGFloat>(cue->size() * (_textLayer.bounds.size.width) * 0.01);
      NSStringDrawingOptions options = NSStringDrawingUsesLineFragmentOrigin;
      // TODO: Sometimes, if the system font size is set high, this will make very wrong estimates.
      CGSize effectiveSize = [line boundingRectWithSize:CGSizeMake(width, 9999)
                                                options:options
                                             attributes:@{NSFontAttributeName: font}
                                                context:nil]
                                 .size;
      // The size estimates don't always seem to be 100% accurate, so this adds a bit to the width.
      width = ceil(effectiveSize.width) + 16;
      CGFloat height = ceil(effectiveSize.height);
      CGFloat x = (_textLayer.bounds.size.width - width) * 0.5f;
      cueLayer.frame = CGRectMake(x, 0, width, height);

      [_textLayer addSublayer:cueLayer];
      [layers addObject:cueLayer];
    }
    [_cues setObject:layers forKey:[NSValue valueWithPointer:cue.get()]];
  }

  // Remove any existing cues that aren't active anymore.
  std::unordered_set<shaka::media::VTTCue *> activeCuesSet;
  for (auto &cue : activeCues)
    activeCuesSet.insert(cue.get());
  NSMutableSet<CALayer *> *expectedLayers = [[NSMutableSet alloc] init];
  for (NSValue *cue in [_cues allKeys]) {
    if (activeCuesSet.count(reinterpret_cast<shaka::media::VTTCue *>([cue pointerValue])) == 0) {
      // Since the layers aren't added to "expectedLayers", they will be removed below.
      [_cues removeObjectForKey:cue];
    } else {
      NSSet<CALayer *> *layers = _cues[cue];
      [expectedLayers unionSet:layers];
    }
  }

  // Remove any layers in the view that aren't associated with any cues.
  for (CALayer *layer in [_textLayer.sublayers copy]) {
    if (![expectedLayers containsObject:layer])
      [layer removeFromSuperlayer];
  }

  // Move all the remaining layers to appear at the bottom of the screen.
  CGFloat y = _textLayer.bounds.size.height;
  for (auto i = _textLayer.sublayers.count; i > 0; i--) {
    // Read the cue layers in inverse order, since they are being drawn from the bottom up.
    CALayer *cueLayer = _textLayer.sublayers[i - 1];

    CGSize size = cueLayer.frame.size;
    y -= size.height;
    cueLayer.frame = CGRectMake(cueLayer.frame.origin.x, y, size.width, size.height);
  }
}

@end
