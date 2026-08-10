#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DiscordStatusChangedBlock)(
    BOOL ready,
    NSString *text
);

typedef void (^DiscordPresenceResultBlock)(
    NSString *presenceID,
    BOOL success
);

@interface DiscordBridge : NSObject

@property (nonatomic, copy, nullable)
DiscordStatusChangedBlock onStatusChanged;

@property (nonatomic, copy, nullable)
DiscordPresenceResultBlock onPresenceResult;

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
                     presenceID:(NSString *)presenceID
                 startTimestamp:(int64_t)startTimestamp
                   endTimestamp:(int64_t)endTimestamp
    NS_SWIFT_NAME(updatePresence(title:artist:album:songURL:artworkURL:presenceID:startTimestamp:endTimestamp:));

- (void)clearPresence;

@end

NS_ASSUME_NONNULL_END
