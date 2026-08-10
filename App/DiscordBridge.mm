#import "DiscordBridge.h"
#import <Security/Security.h>

#define DISCORDPP_IMPLEMENTATION
#include "discordpp.h"

#include <memory>
#include <optional>
#include <string>


// MARK: =========================================
// MARK: Helpers
// MARK: =========================================

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


static NSString * const DiscordTokenService =
    @"AppleMusicDiscordPresence.DiscordOAuth.v1";


static std::string NSStringToString(
    NSString *value
) {

    if (!value) {
        return "";
    }

    const char *utf8 =
        value.UTF8String;

    if (!utf8) {
        return "";
    }

    return std::string(
        utf8
    );
}


static NSString *StringToNSString(
    const std::string &value
) {

    NSString *result =
        [NSString stringWithUTF8String:
            value.c_str()
        ];

    return result ?: @"";
}


static std::optional<std::string>
NSStringToOptionalString(
    NSString *value
) {

    if (!value ||
        value.length == 0) {

        return std::nullopt;
    }

    return NSStringToString(
        value
    );
}


static NSString *TokenAccount(
    uint64_t applicationID
) {

    return
        [NSString stringWithFormat:
            @"%llu",
            (unsigned long long)applicationID
        ];
}


// MARK: =========================================
// MARK: Keychain
// MARK: =========================================

static NSDictionary *BaseKeychainQuery(
    uint64_t applicationID
) {

    return @{

        (__bridge id)kSecClass:
            (__bridge id)
                kSecClassGenericPassword,

        (__bridge id)kSecAttrService:
            DiscordTokenService,

        (__bridge id)kSecAttrAccount:
            TokenAccount(
                applicationID
            )
    };
}


static NSDictionary *LoadTokenPayload(
    uint64_t applicationID
) {

    NSMutableDictionary *query =
        [
            BaseKeychainQuery(
                applicationID
            )
            mutableCopy
        ];


    query[
        (__bridge id)kSecReturnData
    ] = @YES;


    query[
        (__bridge id)kSecMatchLimit
    ] =
        (__bridge id)
            kSecMatchLimitOne;


    CFTypeRef result = NULL;


    OSStatus status =
        SecItemCopyMatching(
            (__bridge CFDictionaryRef)
                query,
            &result
        );


    if (status != errSecSuccess ||
        result == NULL) {

        return nil;
    }


    NSData *data =
        (__bridge_transfer NSData *)
            result;


    if (!data) {
        return nil;
    }


    NSError *error = nil;


    id object =
        [NSJSONSerialization
            JSONObjectWithData:data
            options:0
            error:&error
        ];


    if (error ||
        ![
            object
            isKindOfClass:
                [NSDictionary class]
        ]) {

        return nil;
    }


    return
        (NSDictionary *)object;
}


static BOOL SaveTokenPayload(
    uint64_t applicationID,
    NSDictionary *payload
) {

    NSError *error = nil;


    NSData *data =
        [NSJSONSerialization
            dataWithJSONObject:
                payload
            options:0
            error:&error
        ];


    if (error ||
        !data) {

        return NO;
    }


    NSDictionary *baseQuery =
        BaseKeychainQuery(
            applicationID
        );


    NSDictionary *attributes = @{

        (__bridge id)kSecValueData:
            data,

        (__bridge id)kSecAttrAccessible:
            (__bridge id)
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    };


    OSStatus status =
        SecItemUpdate(
            (__bridge CFDictionaryRef)
                baseQuery,

            (__bridge CFDictionaryRef)
                attributes
        );


    if (status ==
        errSecItemNotFound) {

        NSMutableDictionary *newItem =
            [
                baseQuery
                mutableCopy
            ];


        [
            newItem
            addEntriesFromDictionary:
                attributes
        ];


        status =
            SecItemAdd(
                (__bridge CFDictionaryRef)
                    newItem,
                NULL
            );
    }


    return
        status == errSecSuccess;
}


static void DeleteTokenPayload(
    uint64_t applicationID
) {

    NSDictionary *query =
        BaseKeychainQuery(
            applicationID
        );


    SecItemDelete(
        (__bridge CFDictionaryRef)
            query
    );
}

} // namespace


// MARK: =========================================
// MARK: Private interface
// MARK: =========================================

@interface DiscordBridge ()

- (void)notifyReady:(BOOL)ready
               text:(NSString *)text;

- (void)ensureClient;

- (void)loadStoredTokensIfNeeded;

- (void)saveTokensWithAccessToken:
            (NSString *)accessToken
                    refreshToken:
            (NSString *)refreshToken
                       expiresIn:
            (int32_t)expiresIn;

- (void)clearStoredTokens;

- (BOOL)shouldRefreshToken;

- (void)applyStoredAccessTokenAndConnect;

- (void)refreshStoredToken;

- (void)scheduleRefreshRetry:
            (NSTimeInterval)delay;

- (void)beginAuthorization;

- (void)sendPendingPresenceIfPossible;

@end


// MARK: =========================================
// MARK: Implementation
// MARK: =========================================

@implementation DiscordBridge {

    std::shared_ptr<discordpp::Client>
        _client;


    uint64_t
        _applicationID;


    uint64_t
        _tokensLoadedForApplicationID;


    BOOL
        _authorizationRunning;


    BOOL
        _tokenOperationRunning;


    BOOL
        _ready;


    std::string
        _accessToken;


    std::string
        _refreshToken;


    double
        _accessTokenExpiresAt;


    PendingPresence
        _pendingPresence;
}


// MARK: - Singleton

+ (instancetype)shared {

    static DiscordBridge *instance =
        nil;


    static dispatch_once_t onceToken;


    dispatch_once(
        &onceToken,
        ^{

            instance =
                [[DiscordBridge alloc]
                    init
                ];
        }
    );


    return instance;
}


// MARK: - Init

- (instancetype)init {

    self =
        [super init];


    if (self) {

        _applicationID =
            0;


        _tokensLoadedForApplicationID =
            0;


        _authorizationRunning =
            NO;


        _tokenOperationRunning =
            NO;


        _ready =
            NO;


        _accessTokenExpiresAt =
            0;
    }


    return self;
}


// MARK: =========================================
// MARK: Status
// MARK: =========================================

- (void)notifyReady:(BOOL)ready
               text:(NSString *)text {

    _ready =
        ready;


    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            if (self.onStatusChanged) {

                self.onStatusChanged(
                    ready,
                    text
                );
            }
        }
    );
}


// MARK: =========================================
// MARK: Client
// MARK: =========================================

- (void)ensureClient {

    if (_client) {
        return;
    }


    _client =
        std::make_shared<
            discordpp::Client
        >();


    __weak DiscordBridge *weakSelf =
        self;


    // MARK: Connection status

    _client->SetStatusChangedCallback(

        [weakSelf](
            discordpp::Client::Status status,
            discordpp::Client::Error error,
            int32_t errorDetail
        ) {

            DiscordBridge *selfRef =
                weakSelf;


            if (!selfRef) {
                return;
            }


            // MARK: Ready

            if (
                status ==
                discordpp::Client::Status::Ready
            ) {

                [selfRef
                    notifyReady:YES
                    text:@"接続済み"
                ];


                dispatch_async(
                    dispatch_get_main_queue(),
                    ^{

                        [selfRef
                            sendPendingPresenceIfPossible
                        ];
                    }
                );


                return;
            }


            // MARK: Connecting

            if (
                status ==
                discordpp::Client::Status::Connecting
            ) {

                [selfRef
                    notifyReady:NO
                    text:@"Discord 接続中"
                ];

                return;
            }


            // MARK: Connected

            if (
                status ==
                discordpp::Client::Status::Connected
            ) {

                [selfRef
                    notifyReady:NO
                    text:@"Discord 初期化中"
                ];

                return;
            }


            // MARK: Reconnecting

            if (
                status ==
                discordpp::Client::Status::Reconnecting
            ) {

                [selfRef
                    notifyReady:NO
                    text:@"Discord 再接続中"
                ];

                return;
            }


            // MARK: Disconnecting

            if (
                status ==
                discordpp::Client::Status::Disconnecting
            ) {

                [selfRef
                    notifyReady:NO
                    text:@"Discord 切断中"
                ];

                return;
            }


            // MARK: HTTP wait

            if (
                status ==
                discordpp::Client::Status::HttpWait
            ) {

                [selfRef
                    notifyReady:NO
                    text:@"Discord 通信待ち"
                ];

                return;
            }


            // MARK: Disconnected

            if (
                status ==
                discordpp::Client::Status::Disconnected
            ) {

                NSString *message =
                    @"Discord 切断 / 復旧待ち";


                if (
                    error !=
                    discordpp::Client::Error::None
                ) {

                    std::string errorText =
                        discordpp::Client::
                            ErrorToString(
                                error
                            );


                    message =
                        [NSString
                            stringWithFormat:
                            @"Discord 切断 (%s:%d)",
                            errorText.c_str(),
                            errorDetail
                        ];
                }


                [selfRef
                    notifyReady:NO
                    text:message
                ];


                /*
                 Tokenが無効 / 古い可能性が高い場合。

                 保存済みrefresh tokenから
                 先に更新を試す。
                 */
                if (
                    error ==
                    discordpp::Client::
                        Error::UnexpectedClose
                    &&
                    !selfRef->
                        _refreshToken.empty()
                ) {

                    dispatch_async(
                        dispatch_get_main_queue(),
                        ^{

                            [selfRef
                                refreshStoredToken
                            ];
                        }
                    );


                    return;
                }


                /*
                 通常の回線瞬断。

                 Discord SDK自身にも
                 Reconnectingはあるが、
                 完全Disconnectedまで落ちた場合の保険。
                 */
                dispatch_after(

                    dispatch_time(
                        DISPATCH_TIME_NOW,
                        (int64_t)(
                            2.0 *
                            NSEC_PER_SEC
                        )
                    ),

                    dispatch_get_main_queue(),

                    ^{

                        [selfRef
                            reconnectIfNeeded
                        ];
                    }
                );
            }
        }
    );


    // MARK: Token expiration

    _client->SetTokenExpirationCallback(

        [weakSelf]() {

            DiscordBridge *selfRef =
                weakSelf;


            if (!selfRef) {
                return;
            }


            /*
             Discordが
             「Tokenの期限が近い」
             と通知した時点でRefresh。
             */
            dispatch_async(
                dispatch_get_main_queue(),
                ^{

                    [selfRef
                        refreshStoredToken
                    ];
                }
            );
        }
    );
}


// MARK: =========================================
// MARK: Keychain load/save
// MARK: =========================================

- (void)loadStoredTokensIfNeeded {

    if (_applicationID == 0) {
        return;
    }


    if (
        _tokensLoadedForApplicationID ==
        _applicationID
    ) {

        return;
    }


    _tokensLoadedForApplicationID =
        _applicationID;


    _accessToken.clear();

    _refreshToken.clear();

    _accessTokenExpiresAt =
        0;


    NSDictionary *payload =
        LoadTokenPayload(
            _applicationID
        );


    if (!payload) {
        return;
    }


    NSString *accessToken =
        payload[
            @"accessToken"
        ];


    NSString *refreshToken =
        payload[
            @"refreshToken"
        ];


    NSNumber *expiresAt =
        payload[
            @"expiresAt"
        ];


    if (
        [accessToken
            isKindOfClass:
                [NSString class]
        ]
    ) {

        _accessToken =
            NSStringToString(
                accessToken
            );
    }


    if (
        [refreshToken
            isKindOfClass:
                [NSString class]
        ]
    ) {

        _refreshToken =
            NSStringToString(
                refreshToken
            );
    }


    if (
        [expiresAt
            isKindOfClass:
                [NSNumber class]
        ]
    ) {

        _accessTokenExpiresAt =
            expiresAt.doubleValue;
    }
}


- (void)saveTokensWithAccessToken:
            (NSString *)accessToken
                    refreshToken:
            (NSString *)refreshToken
                       expiresIn:
            (int32_t)expiresIn {

    if (_applicationID == 0) {
        return;
    }


    _accessToken =
        NSStringToString(
            accessToken
        );


    _refreshToken =
        NSStringToString(
            refreshToken
        );


    NSTimeInterval now =
        [
            NSDate date
        ].timeIntervalSince1970;


    _accessTokenExpiresAt =
        now +
        MAX(
            expiresIn,
            0
        );


    NSDictionary *payload = @{

        @"accessToken":
            accessToken ?: @"",

        @"refreshToken":
            refreshToken ?: @"",

        @"expiresAt":
            @(
                _accessTokenExpiresAt
            )
    };


    BOOL saved =
        SaveTokenPayload(
            _applicationID,
            payload
        );


    if (!saved) {

        NSLog(
            @"Discord token Keychain save failed"
        );
    }
}


- (void)clearStoredTokens {

    if (_applicationID != 0) {

        DeleteTokenPayload(
            _applicationID
        );
    }


    _accessToken.clear();

    _refreshToken.clear();

    _accessTokenExpiresAt =
        0;
}


// MARK: =========================================
// MARK: Token state
// MARK: =========================================

- (BOOL)shouldRefreshToken {

    if (_refreshToken.empty()) {
        return NO;
    }


    /*
     access tokenが無いなら
     refresh tokenを使う。
     */
    if (_accessToken.empty()) {
        return YES;
    }


    /*
     有効期限情報が無い場合も
     refresh可能なら更新する。
     */
    if (_accessTokenExpiresAt <= 0) {
        return YES;
    }


    NSTimeInterval now =
        [
            NSDate date
        ].timeIntervalSince1970;


    /*
     24時間以内に期限切れなら
     先にRefresh。
     */
    const double refreshWindow =
        24.0 *
        60.0 *
        60.0;


    return
        _accessTokenExpiresAt <=
        now + refreshWindow;
}


// MARK: =========================================
// MARK: Start
// MARK: =========================================

- (void)startWithApplicationID:
            (uint64_t)applicationID {

    if (applicationID == 0) {

        [self
            notifyReady:NO
            text:
                @"DISCORD_APP_ID が未設定"
        ];

        return;
    }


    /*
     App IDが変更された場合は
     Tokenキャッシュを読み直す。
     */
    if (
        _applicationID !=
        applicationID
    ) {

        _applicationID =
            applicationID;


        _tokensLoadedForApplicationID =
            0;


        _accessToken.clear();

        _refreshToken.clear();

        _accessTokenExpiresAt =
            0;
    }


    [self
        ensureClient
    ];


    _client->SetApplicationId(
        applicationID
    );


    [self
        loadStoredTokensIfNeeded
    ];


    discordpp::Client::Status status =
        _client->GetStatus();


    if (
        status ==
        discordpp::Client::Status::Ready
    ) {

        [self
            notifyReady:YES
            text:@"接続済み"
        ];


        [self
            sendPendingPresenceIfPossible
        ];


        return;
    }


    /*
     すでに接続処理中なら
     余計な操作をしない。
     */
    if (
        status ==
            discordpp::Client::Status::Connecting
        ||
        status ==
            discordpp::Client::Status::Connected
        ||
        status ==
            discordpp::Client::Status::Reconnecting
        ||
        status ==
            discordpp::Client::Status::Disconnecting
        ||
        status ==
            discordpp::Client::Status::HttpWait
    ) {

        return;
    }


    if (
        _authorizationRunning ||
        _tokenOperationRunning
    ) {

        return;
    }


    // MARK: 期限が近い → refresh

    if (
        [self
            shouldRefreshToken
        ]
    ) {

        [self
            refreshStoredToken
        ];

        return;
    }


    // MARK: KeychainのAccess Token

    if (!_accessToken.empty()) {

        [self
            applyStoredAccessTokenAndConnect
        ];

        return;
    }


    // MARK: Access無し、Refresh有り

    if (!_refreshToken.empty()) {

        [self
            refreshStoredToken
        ];

        return;
    }


    /*
     保存済みTokenが一切無い。

     ここだけDiscord認証画面を開く。
     */
    [self
        beginAuthorization
    ];
}


// MARK: =========================================
// MARK: Restore Access Token
// MARK: =========================================

- (void)applyStoredAccessTokenAndConnect {

    if (!_client ||
        _accessToken.empty()) {

        return;
    }


    if (_tokenOperationRunning) {
        return;
    }


    _tokenOperationRunning =
        YES;


    [self
        notifyReady:NO
        text:@"保存済みDiscord認証を復元中"
    ];


    std::string accessToken =
        _accessToken;


    __weak DiscordBridge *weakSelf =
        self;


    _client->UpdateToken(

        discordpp::
            AuthorizationTokenType::Bearer,

        accessToken,

        [weakSelf](
            discordpp::ClientResult result
        ) {

            DiscordBridge *selfRef =
                weakSelf;


            if (!selfRef) {
                return;
            }


            selfRef->
                _tokenOperationRunning =
                NO;


            if (!result.Successful()) {

                [selfRef
                    notifyReady:NO
                    text:
                        @"保存済みTokenの復元失敗"
                ];


                /*
                 Access Tokenが駄目なら
                 Refresh Tokenへ切り替える。
                 */
                if (
                    !selfRef->
                        _refreshToken.empty()
                ) {

                    dispatch_async(
                        dispatch_get_main_queue(),
                        ^{

                            [selfRef
                                refreshStoredToken
                            ];
                        }
                    );
                }


                return;
            }


            if (!selfRef->_client) {
                return;
            }


            [selfRef
                notifyReady:NO
                text:@"Discord 自動接続中"
            ];


            selfRef->
                _client->Connect();
        }
    );
}


// MARK: =========================================
// MARK: Refresh Token
// MARK: =========================================

- (void)refreshStoredToken {

    if (!_client ||
        _applicationID == 0) {

        return;
    }


    if (_tokenOperationRunning ||
        _authorizationRunning) {

        return;
    }


    [self
        loadStoredTokensIfNeeded
    ];


    if (_refreshToken.empty()) {

        /*
         Refresh Token自体が無い場合のみ
         OAuthへ戻る。
         */
        [self
            beginAuthorization
        ];

        return;
    }


    _tokenOperationRunning =
        YES;


    [self
        notifyReady:NO
        text:@"Discord認証を自動更新中"
    ];


    uint64_t applicationID =
        _applicationID;


    std::string oldRefreshToken =
        _refreshToken;


    __weak DiscordBridge *weakSelf =
        self;


    _client->RefreshToken(

        applicationID,

        oldRefreshToken,

        [weakSelf, oldRefreshToken](
            discordpp::ClientResult result,
            std::string accessToken,
            std::string refreshToken,
            discordpp::AuthorizationTokenType tokenType,
            int32_t expiresIn,
            std::string scopes
        ) {

            DiscordBridge *selfRef =
                weakSelf;


            if (!selfRef) {
                return;
            }


            selfRef->
                _tokenOperationRunning =
                NO;


            // MARK: Refresh failed

            if (!result.Successful()) {

                NSLog(
                    @"Discord RefreshToken failed: %s",
                    result.Error().c_str()
                );


                /*
                 回線問題・Rate Limit等。

                 Tokenを消さない。
                 OAuth画面にも戻らない。
                 後で再試行。
                 */
                if (result.Retryable()) {

                    [selfRef
                        notifyReady:NO
                        text:
                            @"Discord認証更新を再試行中"
                    ];


                    NSTimeInterval delay =
                        result.RetryAfter();


                    if (delay < 5) {
                        delay = 15;
                    }


                    if (delay > 60) {
                        delay = 60;
                    }


                    [selfRef
                        scheduleRefreshRetry:
                            delay
                    ];


                    return;
                }


                /*
                 retry不可。

                 Refresh Token自体が
                 無効/失効した可能性が高い。

                 この場合だけ保存を消して
                 再認証する。
                 */
                [selfRef
                    clearStoredTokens
                ];


                [selfRef
                    notifyReady:NO
                    text:
                        @"Discord 再認証が必要"
                ];


                dispatch_after(

                    dispatch_time(
                        DISPATCH_TIME_NOW,
                        (int64_t)(
                            1.0 *
                            NSEC_PER_SEC
                        )
                    ),

                    dispatch_get_main_queue(),

                    ^{

                        [selfRef
                            beginAuthorization
                        ];
                    }
                );


                return;
            }


            // MARK: Refresh success

            /*
             DiscordのRefreshでは
             新しいaccess/refresh tokenが返る。

             古いtokenは無効になる。
             */
            if (accessToken.empty() ||
                refreshToken.empty()) {

                [selfRef
                    clearStoredTokens
                ];


                [selfRef
                    notifyReady:NO
                    text:
                        @"Discord 再認証が必要"
                ];


                dispatch_async(
                    dispatch_get_main_queue(),
                    ^{

                        [selfRef
                            beginAuthorization
                        ];
                    }
                );


                return;
            }


            NSString *accessString =
                StringToNSString(
                    accessToken
                );


            NSString *refreshString =
                StringToNSString(
                    refreshToken
                );


            [selfRef
                saveTokensWithAccessToken:
                    accessString
                refreshToken:
                    refreshString
                expiresIn:
                    expiresIn
            ];


            if (!selfRef->_client) {
                return;
            }


            selfRef->
                _tokenOperationRunning =
                YES;


            selfRef->_client->UpdateToken(

                tokenType,

                accessToken,

                [weakSelf](
                    discordpp::ClientResult
                        updateResult
                ) {

                    DiscordBridge *self2 =
                        weakSelf;


                    if (!self2) {
                        return;
                    }


                    self2->
                        _tokenOperationRunning =
                        NO;


                    if (
                        !updateResult.Successful()
                    ) {

                        [self2
                            notifyReady:NO
                            text:
                                @"Discord Token更新失敗"
                        ];

                        return;
                    }


                    if (!self2->_client) {
                        return;
                    }


                    discordpp::
                        Client::Status
                        status =
                            self2->
                                _client->
                                GetStatus();


                    /*
                     既にReadyなら
                     UpdateTokenだけでOK。
                     */
                    if (
                        status ==
                        discordpp::
                            Client::Status::Ready
                    ) {

                        [self2
                            notifyReady:YES
                            text:@"接続済み"
                        ];


                        [self2
                            sendPendingPresenceIfPossible
                        ];


                        return;
                    }


                    /*
                     完全切断中なら
                     新しいTokenで接続。
                     */
                    if (
                        status ==
                        discordpp::
                            Client::Status::
                                Disconnected
                    ) {

                        [self2
                            notifyReady:NO
                            text:
                                @"Discord 再接続中"
                        ];


                        self2->
                            _client->
                            Connect();
                    }
                }
            );
        }
    );
}


// MARK: - Refresh retry

- (void)scheduleRefreshRetry:
            (NSTimeInterval)delay {

    if (delay < 1) {
        delay = 1;
    }


    dispatch_after(

        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(
                delay *
                NSEC_PER_SEC
            )
        ),

        dispatch_get_main_queue(),

        ^{

            [self
                refreshStoredToken
            ];
        }
    );
}


// MARK: =========================================
// MARK: First Authorization
// MARK: =========================================

- (void)beginAuthorization {

    if (!_client ||
        _applicationID == 0) {

        return;
    }


    if (_authorizationRunning ||
        _tokenOperationRunning) {

        return;
    }


    _authorizationRunning =
        YES;


    [self
        notifyReady:NO
        text:@"Discord 初回認証"
    ];


    auto verifier =
        _client->
            CreateAuthorizationCodeVerifier();


    discordpp::AuthorizationArgs
        args{};


    args.SetClientId(
        _applicationID
    );


    args.SetScopes(
        discordpp::Client::
            GetDefaultPresenceScopes()
    );


    args.SetCodeChallenge(
        verifier.Challenge()
    );


    __weak DiscordBridge *weakSelf =
        self;


    uint64_t applicationID =
        _applicationID;


    _client->Authorize(

        args,

        [weakSelf,
         verifier,
         applicationID](
            discordpp::ClientResult result,
            std::string code,
            std::string redirectUri
        ) {

            DiscordBridge *selfRef =
                weakSelf;


            if (!selfRef) {
                return;
            }


            if (!result.Successful()) {

                selfRef->
                    _authorizationRunning =
                    NO;


                [selfRef
                    notifyReady:NO
                    text:@"Discord 認証失敗"
                ];


                return;
            }


            if (!selfRef->_client) {

                selfRef->
                    _authorizationRunning =
                    NO;

                return;
            }


            selfRef->_client->GetToken(

                applicationID,

                code,

                verifier.Verifier(),

                redirectUri,

                [weakSelf](
                    discordpp::ClientResult
                        tokenResult,

                    std::string
                        accessToken,

                    std::string
                        refreshToken,

                    discordpp::
                        AuthorizationTokenType
                        tokenType,

                    int32_t
                        expiresIn,

                    std::string
                        scopes
                ) {

                    DiscordBridge *self2 =
                        weakSelf;


                    if (!self2) {
                        return;
                    }


                    self2->
                        _authorizationRunning =
                        NO;


                    if (
                        !tokenResult.Successful()
                    ) {

                        [self2
                            notifyReady:NO
                            text:
                                @"Discord Token取得失敗"
                        ];

                        return;
                    }


                    // MARK: SAVE TO KEYCHAIN

                    NSString *accessString =
                        StringToNSString(
                            accessToken
                        );


                    NSString *refreshString =
                        StringToNSString(
                            refreshToken
                        );


                    [self2
                        saveTokensWithAccessToken:
                            accessString
                        refreshToken:
                            refreshString
                        expiresIn:
                            expiresIn
                    ];


                    if (!self2->_client) {
                        return;
                    }


                    self2->
                        _tokenOperationRunning =
                        YES;


                    self2->_client->UpdateToken(

                        tokenType,

                        accessToken,

                        [weakSelf](
                            discordpp::
                                ClientResult
                                updateResult
                        ) {

                            DiscordBridge *self3 =
                                weakSelf;


                            if (!self3) {
                                return;
                            }


                            self3->
                                _tokenOperationRunning =
                                NO;


                            if (
                                !updateResult.Successful()
                            ) {

                                [self3
                                    notifyReady:NO
                                    text:
                                        @"Discord Token設定失敗"
                                ];

                                return;
                            }


                            if (!self3->_client) {
                                return;
                            }


                            [self3
                                notifyReady:NO
                                text:
                                    @"Discord 接続中"
                            ];


                            self3->
                                _client->
                                Connect();
                        }
                    );
                }
            );
        }
    );
}


// MARK: =========================================
// MARK: Reconnect
// MARK: =========================================

- (void)reconnectIfNeeded {

    if (!_client ||
        _applicationID == 0) {

        return;
    }


    discordpp::Client::Status status =
        _client->GetStatus();


    // MARK: Already ready

    if (
        status ==
        discordpp::Client::Status::Ready
    ) {

        if (!_ready) {

            [self
                notifyReady:YES
                text:@"接続済み"
            ];
        }


        [self
            sendPendingPresenceIfPossible
        ];


        return;
    }


    /*
     SDK自身が処理中なら邪魔しない。
     */
    if (
        status ==
            discordpp::Client::Status::Connecting
        ||
        status ==
            discordpp::Client::Status::Connected
        ||
        status ==
            discordpp::Client::Status::Reconnecting
        ||
        status ==
            discordpp::Client::Status::Disconnecting
        ||
        status ==
            discordpp::Client::Status::HttpWait
    ) {

        return;
    }


    if (
        _authorizationRunning ||
        _tokenOperationRunning
    ) {

        return;
    }


    [self
        loadStoredTokensIfNeeded
    ];


    // MARK: Refresh first

    if (
        [self
            shouldRefreshToken
        ]
    ) {

        [self
            refreshStoredToken
        ];

        return;
    }


    /*
     SDKにすでにTokenが入っている場合。

     Wi-Fi → モバイル
     VPN ON → OFF
     瞬断

     などではここ。
     */
    if (_client->IsAuthenticated()) {

        [self
            notifyReady:NO
            text:@"Discord 再接続中"
        ];


        _client->Connect();

        return;
    }


    // MARK: Restore Keychain Access Token

    if (!_accessToken.empty()) {

        [self
            applyStoredAccessTokenAndConnect
        ];

        return;
    }


    // MARK: Refresh only

    if (!_refreshToken.empty()) {

        [self
            refreshStoredToken
        ];

        return;
    }


    /*
     本当に認証情報が無い時だけ。
     */
    [self
        beginAuthorization
    ];
}


// MARK: =========================================
// MARK: Run callbacks
// MARK: =========================================

- (void)runCallbacks {

    discordpp::RunCallbacks();
}


// MARK: =========================================
// MARK: Presence
// MARK: =========================================

- (void)updatePresenceWithTitle:
            (NSString *)title
                         artist:
            (NSString *)artist
                          album:
            (NSString *)album
                        songURL:
            (NSString * _Nullable)songURL
                     artworkURL:
            (NSString * _Nullable)artworkURL
                 startTimestamp:
            (int64_t)startTimestamp
                   endTimestamp:
            (int64_t)endTimestamp {

    /*
     Discordが切断中でも
     最新の曲を保存する。

     Readyへ戻った瞬間に
     これを再送する。
     */
    _pendingPresence.valid =
        true;


    _pendingPresence.title =
        NSStringToString(
            title
        );


    _pendingPresence.artist =
        NSStringToString(
            artist
        );


    _pendingPresence.album =
        NSStringToString(
            album
        );


    _pendingPresence.songURL =
        NSStringToOptionalString(
            songURL
        );


    _pendingPresence.artworkURL =
        NSStringToOptionalString(
            artworkURL
        );


    _pendingPresence.startTimestamp =
        startTimestamp;


    _pendingPresence.endTimestamp =
        endTimestamp;


    [self
        sendPendingPresenceIfPossible
    ];
}


// MARK: - Send Pending Presence

- (void)sendPendingPresenceIfPossible {

    if (!_client) {
        return;
    }


    if (!_pendingPresence.valid) {
        return;
    }


    if (
        _client->GetStatus() !=
        discordpp::Client::Status::Ready
    ) {

        return;
    }


    const PendingPresence presence =
        _pendingPresence;


    discordpp::Activity activity;


    activity.SetType(
        discordpp::
            ActivityTypes::Listening
    );


    // 曲名

    activity.SetDetails(
        presence.title
    );


    // Artist

    activity.SetState(
        presence.artist
    );


    // Apple Music URL

    if (
        presence.songURL.has_value()
    ) {

        activity.SetDetailsUrl(
            presence.songURL.value()
        );
    }


    // MARK: Time

    discordpp::ActivityTimestamps
        timestamps;


    if (
        presence.startTimestamp > 0
    ) {

        timestamps.SetStart(
            presence.startTimestamp
        );
    }


    if (
        presence.endTimestamp > 0
    ) {

        timestamps.SetEnd(
            presence.endTimestamp
        );
    }


    activity.SetTimestamps(
        timestamps
    );


    // MARK: Artwork

    discordpp::ActivityAssets
        assets;


    if (
        presence.artworkURL.has_value()
    ) {

        /*
         今まで動いていた
         曲ジャケットURLをそのまま使用。
         */
        assets.SetLargeImage(
            presence.artworkURL.value()
        );

    } else {

        /*
         Artworkが本当に取得不能な時だけ
         SDKに登録したApple Music画像。
         */
        assets.SetLargeImage(
            "applemusic"
        );
    }


    // Album tooltip

    if (
        presence.album.length() >= 2
    ) {

        std::string albumText =
            presence.album;


        if (
            albumText.length() > 128
        ) {

            albumText =
                albumText.substr(
                    0,
                    128
                );
        }


        assets.SetLargeText(
            albumText
        );
    }


    // Artwork tap → Apple Music

    if (
        presence.songURL.has_value()
    ) {

        const std::string &url =
            presence.songURL.value();


        if (
            url.length() <= 256
        ) {

            assets.SetLargeUrl(
                url
            );
        }
    }


    activity.SetAssets(
        assets
    );


    __weak DiscordBridge *weakSelf =
        self;


    _client->UpdateRichPresence(

        activity,

        [weakSelf](
            discordpp::ClientResult result
        ) {

            DiscordBridge *selfRef =
                weakSelf;


            if (!selfRef) {
                return;
            }


            if (!result.Successful()) {

                NSLog(
                    @"UpdateRichPresence failed: %s",
                    result.Error().c_str()
                );


                /*
                 Presenceは消さない。

                 pendingPresenceは残っているので
                 再接続時に最新曲を再送。
                 */
                [selfRef
                    notifyReady:NO
                    text:
                        @"Presence 再送待ち"
                ];


                dispatch_after(

                    dispatch_time(
                        DISPATCH_TIME_NOW,
                        (int64_t)(
                            2.0 *
                            NSEC_PER_SEC
                        )
                    ),

                    dispatch_get_main_queue(),

                    ^{

                        [selfRef
                            reconnectIfNeeded
                        ];
                    }
                );
            }
        }
    );
}


// MARK: =========================================
// MARK: Clear Presence
// MARK: =========================================

- (void)clearPresence {

    /*
     切断中に停止した場合、
     再接続時に古い曲が復活しないよう
     pendingも無効化。
     */
    _pendingPresence.valid =
        false;


    if (!_client) {
        return;
    }


    if (
        _client->GetStatus() !=
        discordpp::Client::Status::Ready
    ) {

        return;
    }


    _client->ClearRichPresence();
}

@end
