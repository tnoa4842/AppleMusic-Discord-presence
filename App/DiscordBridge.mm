#import "DiscordBridge.h"

#define DISCORDPP_IMPLEMENTATION
#include "discordpp.h"

#include <memory>
#include <string>

@implementation DiscordBridge {
    std::shared_ptr<discordpp::Client> _client;
}

+ (instancetype)shared {
    static DiscordBridge *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DiscordBridge alloc] init];
    });
    return shared;
}

- (void)startWithApplicationID:(uint64_t)applicationID {
    if (!_client) {
        _client = std::make_shared<discordpp::Client>();
    }

    _client->SetApplicationId(applicationID);

    __weak DiscordBridge *weakSelf = self;

    _client->SetStatusChangedCallback(
        [weakSelf](discordpp::Client::Status status,
                   discordpp::Client::Error error,
                   int32_t errorDetail) {
            DiscordBridge *selfRef = weakSelf;
            if (!selfRef) return;

            BOOL ready = status == discordpp::Client::Status::Ready;
            NSString *message = ready ? @"接続済み" : @"接続中";

            dispatch_async(dispatch_get_main_queue(), ^{
                if (selfRef.onStatusChanged) {
                    selfRef.onStatusChanged(ready, message);
                }
            });
        }
    );

    auto verifier = _client->CreateAuthorizationCodeVerifier();

    discordpp::AuthorizationArgs args{};
    args.SetClientId(applicationID);
    args.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
    args.SetCodeChallenge(verifier.Challenge());

    _client->Authorize(
        args,
        [weakSelf, verifier, applicationID](auto result, auto code, auto redirectUri) {
            DiscordBridge *selfRef = weakSelf;
            if (!selfRef || !selfRef->_client) return;

            if (!result.Successful()) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (selfRef.onStatusChanged)
                        selfRef.onStatusChanged(NO, @"Discord 認証失敗");
                });
                return;
            }

            selfRef->_client->GetToken(
                applicationID,
                code,
                verifier.Verifier(),
                redirectUri,
                [weakSelf](auto tokenResult,
                           auto accessToken,
                           auto refreshToken,
                           auto expiresIn,
                           auto scopes,
                           auto tokenType) {
                    DiscordBridge *self2 = weakSelf;
                    if (!self2 || !self2->_client) return;

                    if (!tokenResult.Successful()) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (self2.onStatusChanged)
                                self2.onStatusChanged(NO, @"Discord Token 取得失敗");
                        });
                        return;
                    }

                    self2->_client->UpdateToken(
                        discordpp::AuthorizationTokenType::Bearer,
                        accessToken,
                        [weakSelf](auto updateResult) {
                            DiscordBridge *self3 = weakSelf;
                            if (!self3 || !self3->_client) return;
                            if (updateResult.Successful()) {
                                self3->_client->Connect();
                            }
                        }
                    );
                }
            );
        }
    );
}

- (void)runCallbacks {
    discordpp::RunCallbacks();
}

- (void)updatePresenceWithTitle:(NSString *)title
                         artist:(NSString *)artist
                          album:(NSString *)album
                        songURL:(NSString * _Nullable)songURL
                 startTimestamp:(int64_t)startTimestamp
                   endTimestamp:(int64_t)endTimestamp {
    if (!_client) return;

    discordpp::Activity activity;
    activity.SetType(discordpp::ActivityTypes::Listening);
    activity.SetDetails(std::string(title.UTF8String ?: ""));
    activity.SetState(std::string(artist.UTF8String ?: ""));

    if (songURL.length > 0) {
        activity.SetDetailsUrl(std::string(songURL.UTF8String ?: ""));
    }

    discordpp::ActivityTimestamps timestamps;
    if (startTimestamp > 0) timestamps.SetStart(startTimestamp);
    if (endTimestamp > 0) timestamps.SetEnd(endTimestamp);
    activity.SetTimestamps(timestamps);

    discordpp::ActivityAssets assets;
    assets.SetLargeImage("applemusic");
    if (album.length > 0)
        assets.SetLargeText(std::string(album.UTF8String ?: ""));
    activity.SetAssets(assets);

    _client->UpdateRichPresence(activity, [](discordpp::ClientResult result) {
        if (!result.Successful()) {
            NSLog(@"UpdateRichPresence failed");
        }
    });
}

- (void)clearPresence {
    if (!_client) return;

    // Social SDK の現行版で ClearRichPresence が利用できる場合。
    // SDK版で名称差がある場合は compile-fix workflow のログを確認。
    _client->ClearRichPresence();
}

@end
