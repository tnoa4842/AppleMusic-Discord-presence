#import "DiscordBridge.h"

#define DISCORDPP_IMPLEMENTATION
#include "discordpp.h"

#include <memory>
#include <string>
#include <optional>

namespace {

struct PendingPresence {
    bool valid = false;

    std::string title;
    std::string artist;
    std::string album;

    std::optional<std::string> songURL;
    std::optional<std::string> artworkURL;

    int64_t startTimestamp = 0;
    int64_t endTimestamp = 0;
};

static std::string NSStringToString(NSString *value) {
    if (!value) {
        return "";
    }

    const char *utf8 = value.UTF8String;

    if (!utf8) {
        return "";
    }

    return std::string(utf8);
}

static std::optional<std::string> NSStringToOptionalString(NSString *value) {
    if (!value || value.length == 0) {
        return std::nullopt;
    }

    const char *utf8 = value.UTF8String;

    if (!utf8) {
        return std::nullopt;
    }

    return std::string(utf8);
}

} // namespace


@interface DiscordBridge ()
- (void)notifyReady:(BOOL)ready text:(NSString *)text;
- (void)authorizeIfNeeded;
- (void)sendPendingPresenceIfPossible;
@end


@implementation DiscordBridge {
    std::shared_ptr<discordpp::Client> _client;

    uint64_t _applicationID;

    BOOL _authorizationRunning;
    BOOL _hasUsableToken;
    BOOL _ready;

    PendingPresence _pendingPresence;
}


+ (instancetype)shared {
    static DiscordBridge *sharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sharedInstance = [[DiscordBridge alloc] init];
    });

    return sharedInstance;
}


- (instancetype)init {
    self = [super init];

    if (self) {
        _applicationID = 0;
        _authorizationRunning = NO;
        _hasUsableToken = NO;
        _ready = NO;
    }

    return self;
}


#pragma mark - Status


- (void)notifyReady:(BOOL)ready text:(NSString *)text {
    _ready = ready;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onStatusChanged) {
            self.onStatusChanged(ready, text);
        }
    });
}


#pragma mark - Start


- (void)startWithApplicationID:(uint64_t)applicationID {
    if (applicationID == 0) {
        [self notifyReady:NO text:@"DISCORD_APP_ID が未設定"];
        return;
    }

    _applicationID = applicationID;

    if (!_client) {
        _client = std::make_shared<discordpp::Client>();

        _client->SetApplicationId(applicationID);

        __weak DiscordBridge *weakSelf = self;

        _client->SetStatusChangedCallback(
            [weakSelf](
                discordpp::Client::Status status,
                discordpp::Client::Error error,
                int32_t errorDetail
            ) {
                DiscordBridge *selfRef = weakSelf;

                if (!selfRef) {
                    return;
                }

                switch (status) {

                    case discordpp::Client::Status::Ready: {
                        [selfRef notifyReady:YES text:@"接続済み"];

                        dispatch_async(dispatch_get_main_queue(), ^{
                            [selfRef sendPendingPresenceIfPossible];
                        });

                        break;
                    }

                    case discordpp::Client::Status::Connecting: {
                        [selfRef notifyReady:NO text:@"Discord 接続中"];
                        break;
                    }

                    case discordpp::Client::Status::Connected: {
                        [selfRef notifyReady:NO text:@"Discord 初期化中"];
                        break;
                    }

                    case discordpp::Client::Status::Reconnecting: {
                        [selfRef notifyReady:NO text:@"Discord 再接続中"];
                        break;
                    }

                    case discordpp::Client::Status::Disconnecting: {
                        [selfRef notifyReady:NO text:@"Discord 切断中"];
                        break;
                    }

                    case discordpp::Client::Status::HttpWait: {
                        [selfRef notifyReady:NO text:@"Discord 待機中"];
                        break;
                    }

                    case discordpp::Client::Status::Disconnected: {
                        [selfRef notifyReady:NO text:@"Discord 切断"];

                        /*
                         * SDK自身にもReconnect機構はある。
                         *
                         * ただし完全にDisconnectedまで落ちた場合だけ、
                         * 少し待ってこちらからもConnectを試す。
                         *
                         * Reconnecting中にConnectを連打しないのが重要。
                         */
                        if (selfRef->_hasUsableToken &&
                            selfRef->_client) {

                            dispatch_after(
                                dispatch_time(
                                    DISPATCH_TIME_NOW,
                                    (int64_t)(2.0 * NSEC_PER_SEC)
                                ),
                                dispatch_get_main_queue(),
                                ^{
                                    [selfRef reconnectIfNeeded];
                                }
                            );
                        }

                        break;
                    }
                }
            }
        );
    } else {
        /*
         * すでにClientが存在する場合でも、
         * App IDは改めて保証する。
         */
        _client->SetApplicationId(applicationID);
    }


    const auto status = _client->GetStatus();

    if (status == discordpp::Client::Status::Ready) {
        [self notifyReady:YES text:@"接続済み"];
        [self sendPendingPresenceIfPossible];
        return;
    }

    if (status == discordpp::Client::Status::Connecting ||
        status == discordpp::Client::Status::Connected ||
        status == discordpp::Client::Status::Reconnecting ||
        status == discordpp::Client::Status::HttpWait) {

        return;
    }


    if (_hasUsableToken) {
        _client->Connect();
        return;
    }


    [self authorizeIfNeeded];
}


#pragma mark - Authorization


- (void)authorizeIfNeeded {
    if (!_client) {
        return;
    }

    if (_applicationID == 0) {
        return;
    }

    if (_authorizationRunning) {
        return;
    }

    _authorizationRunning = YES;

    [self notifyReady:NO text:@"Discord 認証中"];

    auto verifier = _client->CreateAuthorizationCodeVerifier();

    discordpp::AuthorizationArgs args{};

    args.SetClientId(_applicationID);
    args.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
    args.SetCodeChallenge(verifier.Challenge());


    __weak DiscordBridge *weakSelf = self;

    _client->Authorize(
        args,

        [weakSelf, verifier](
            auto result,
            auto code,
            auto redirectUri
        ) {

            DiscordBridge *selfRef = weakSelf;

            if (!selfRef) {
                return;
            }

            if (!result.Successful()) {
                selfRef->_authorizationRunning = NO;

                [selfRef notifyReady:NO
                                text:@"Discord 認証失敗"];

                return;
            }


            if (!selfRef->_client) {
                selfRef->_authorizationRunning = NO;
                return;
            }


            selfRef->_client->GetToken(
                selfRef->_applicationID,
                code,
                verifier.Verifier(),
                redirectUri,

                [weakSelf](
                    auto tokenResult,
                    auto accessToken,
                    auto refreshToken,
                    auto expiresIn,
                    auto scopes,
                    auto tokenType
                ) {

                    DiscordBridge *self2 = weakSelf;

                    if (!self2) {
                        return;
                    }

                    if (!self2->_client) {
                        self2->_authorizationRunning = NO;
                        return;
                    }


                    if (!tokenResult.Successful()) {
                        self2->_authorizationRunning = NO;

                        [self2 notifyReady:NO
                                     text:@"Discord Token 取得失敗"];

                        return;
                    }


                    self2->_client->UpdateToken(
                        discordpp::AuthorizationTokenType::Bearer,
                        accessToken,

                        [weakSelf](auto updateResult) {

                            DiscordBridge *self3 = weakSelf;

                            if (!self3) {
                                return;
                            }

                            self3->_authorizationRunning = NO;


                            if (!self3->_client) {
                                return;
                            }


                            if (!updateResult.Successful()) {
                                self3->_hasUsableToken = NO;

                                [self3 notifyReady:NO
                                             text:@"Discord Token 設定失敗"];

                                return;
                            }


                            self3->_hasUsableToken = YES;

                            [self3 notifyReady:NO
                                         text:@"Discord 接続中"];

                            self3->_client->Connect();
                        }
                    );
                }
            );
        }
    );
}


#pragma mark - Reconnect


- (void)reconnectIfNeeded {
    if (!_client) {
        return;
    }


    const auto status = _client->GetStatus();


    /*
     * Readyなら何もしない。
     */
    if (status == discordpp::Client::Status::Ready) {
        if (!_ready) {
            [self notifyReady:YES text:@"接続済み"];
        }

        [self sendPendingPresenceIfPossible];
        return;
    }


    /*
     * SDK自身が接続処理中なら邪魔しない。
     */
    if (status == discordpp::Client::Status::Connecting ||
        status == discordpp::Client::Status::Connected ||
        status == discordpp::Client::Status::Reconnecting ||
        status == discordpp::Client::Status::Disconnecting ||
        status == discordpp::Client::Status::HttpWait) {

        return;
    }


    /*
     * 完全にDisconnected。
     *
     * Tokenがまだ有効なら再Connect。
     */
    if (status == discordpp::Client::Status::Disconnected) {

        if (_hasUsableToken) {
            [self notifyReady:NO text:@"Discord 再接続中"];
            _client->Connect();
            return;
        }


        /*
         * Token自体がまだ無い場合だけ認証。
         *
         * 普通のネット切断ではここには来ない。
         */
        if (!_authorizationRunning) {
            [self authorizeIfNeeded];
        }
    }
}


#pragma mark - Callbacks


- (void)runCallbacks {
    discordpp::RunCallbacks();
}


#pragma mark - Presence


- (void)updatePresenceWithTitle:(NSString *)title
                         artist:(NSString *)artist
                          album:(NSString *)album
                        songURL:(NSString * _Nullable)songURL
                     artworkURL:(NSString * _Nullable)artworkURL
                 startTimestamp:(int64_t)startTimestamp
                   endTimestamp:(int64_t)endTimestamp {

    /*
     * まず最新Presenceを必ず保存する。
     *
     * Discordが一瞬切れている最中に曲が変わっても、
     * Ready復帰時に最新曲を送り直せる。
     */
    _pendingPresence.valid = true;

    _pendingPresence.title = NSStringToString(title);
    _pendingPresence.artist = NSStringToString(artist);
    _pendingPresence.album = NSStringToString(album);

    _pendingPresence.songURL = NSStringToOptionalString(songURL);
    _pendingPresence.artworkURL = NSStringToOptionalString(artworkURL);

    _pendingPresence.startTimestamp = startTimestamp;
    _pendingPresence.endTimestamp = endTimestamp;


    [self sendPendingPresenceIfPossible];
}


- (void)sendPendingPresenceIfPossible {
    if (!_client) {
        return;
    }

    if (!_pendingPresence.valid) {
        return;
    }


    const auto status = _client->GetStatus();

    if (status != discordpp::Client::Status::Ready) {
        return;
    }


    const PendingPresence presence = _pendingPresence;


    discordpp::Activity activity;


    /*
     * Discordで
     *
     * 「曲名 を再生中」
     *
     * にする。
     */
    activity.SetName(presence.title);

    activity.SetType(
        discordpp::ActivityTypes::Listening
    );


    /*
     * カード本文
     */
    activity.SetDetails(presence.title);
    activity.SetState(presence.artist);


    /*
     * 曲名クリック → Apple Music
     */
    if (presence.songURL.has_value()) {
        activity.SetDetailsUrl(
            presence.songURL.value()
        );
    }


    /*
     * 再生時間
     */
    discordpp::ActivityTimestamps timestamps;

    if (presence.startTimestamp > 0) {
        timestamps.SetStart(
            presence.startTimestamp
        );
    }

    if (presence.endTimestamp > 0) {
        timestamps.SetEnd(
            presence.endTimestamp
        );
    }

    activity.SetTimestamps(timestamps);


    /*
     * ジャケット
     *
     * artworkURL がある場合だけLargeImageを設定。
     *
     * Swift側で、
     * ・曲IDキャッシュ
     * ・アルバムキャッシュ
     * ・直前Artwork
     *
     * を使ってnilになりにくくしている。
     */
    if (presence.artworkURL.has_value()) {

        discordpp::ActivityAssets assets;

        assets.SetLargeImage(
            presence.artworkURL.value()
        );


        if (!presence.album.empty()) {
            assets.SetLargeText(
                presence.album
            );
        }


        if (presence.songURL.has_value()) {
            assets.SetLargeUrl(
                presence.songURL.value()
            );
        }


        activity.SetAssets(assets);
    }


    __weak DiscordBridge *weakSelf = self;

    _client->UpdateRichPresence(
        activity,

        [weakSelf](discordpp::ClientResult result) {

            DiscordBridge *selfRef = weakSelf;

            if (!selfRef) {
                return;
            }


            if (!result.Successful()) {
                NSLog(
                    @"UpdateRichPresence failed"
                );

                /*
                 * Presenceは消さない。
                 *
                 * _pendingPresence に残っているので、
                 * 接続復帰後に再送できる。
                 */
                [selfRef notifyReady:NO
                                text:@"Presence 再送待ち"];

                dispatch_after(
                    dispatch_time(
                        DISPATCH_TIME_NOW,
                        (int64_t)(2.0 * NSEC_PER_SEC)
                    ),
                    dispatch_get_main_queue(),
                    ^{
                        [selfRef reconnectIfNeeded];
                    }
                );
            }
        }
    );
}


#pragma mark - Clear


- (void)clearPresence {
    _pendingPresence.valid = false;

    if (!_client) {
        return;
    }


    if (_client->GetStatus() !=
        discordpp::Client::Status::Ready) {

        return;
    }


    _client->ClearRichPresence();
}


@end
