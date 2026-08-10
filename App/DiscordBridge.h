#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DiscordStatusChangedBlock)(
    BOOL ready,
    NSString *text
);

@interface DiscordBridge : NSObject

@property (nonatomic, copy, nullable)
DiscordStatusChangedBlock onStatusChanged;

+ (instancetype)shared;

- (void)startWithApplicationID:(uint64_t)applicationID
    NS_SWIFT_NAME(start(withApplicationID:));

- (void)runCallbacks;

- (void)reconnectIfNeeded;

- (void)updatePresenceWithTitle:(NSString *)title
                         artist:(NSString *)artist
                          album:(NSString *)album
                        songURL:(nullable NSString *)songURL
                     artworkURL:(nullable NSString *)artworkURL
                 startTimestamp:(int64_t)startTimestamp
                   endTimestamp:(int64_t)endTimestamp
    NS_SWIFT_NAME(updatePresence(title:artist:album:songURL:artworkURL:startTimestamp:endTimestamp:));

- (void)clearPresence;

@end

NS_ASSUME_NONNULL_END
