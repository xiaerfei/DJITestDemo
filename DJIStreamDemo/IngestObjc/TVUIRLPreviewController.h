#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLPreviewController : NSObject

@property (nonatomic, strong, readonly) UIView *view;
@property (nonatomic, weak, nullable) id delegate;

- (instancetype)init;
- (void)updateFrame:(CVPixelBufferRef)pixelBuffer;
- (void)clearFrame;

@end

NS_ASSUME_NONNULL_END
