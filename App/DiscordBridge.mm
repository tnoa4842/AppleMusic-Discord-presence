#import "DiscordBridge.h"
#import <Security/Security.h>

#define DISCORDPP_IMPLEMENTATION
#include "discordpp.h"

#include <memory>
#include <optional>
#include <string>


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

    return std::string(utf8);
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

    return NSStringToString(value);
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


// MARK: - Keychain


static NSDictionary *BaseKeychainQuery(
    uint64_t applicationID
) {
    return @{
        (__bridge id)kSecClass:
            (__bridge id)kSecClassGenericPassword,

        (__bridge id)kSecAttrService:
            DiscordTokenService,

        (__bridge id)kSecAttrAccount:
            TokenAccount(applicationID)
    };
}


static NSDictionary *LoadTokenPayload(
    uint64_t applicationID
) {
    NSMutableDictionary *query =
        [
            BaseKeychainQuery(applicationID)
            mutableCopy
        ];

    query[
        (__bridge id)kSecReturnData
    ] = @YES;

    query[
        (__bridge id)kSecMatchLimit
    ] =
        (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;

    OSStatus status =
        SecItemCopyMatching(
            (__bridge CFDictionaryRef)query,
            &result
        );

    if (status != errSecSuccess ||
        result == NULL) {

        return nil;
    }

    NSData *data =
        (__bridge_transfer NSData *)result;

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
            isKindOfClass:[NSDictionary class]
        ]) {

        return nil;
    }

    return (NSDictionary *)object;
}


static BOOL SaveTokenPayload(
    uint64_t applicationID,
    NSDictionary *payload
) {
    NSError *error = nil;

    NSData *data =
        [NSJSONSerialization
            dataWithJSONObject:payload
            options:0
            error:&error
        ];

    if (error || !data) {
        return NO;
    }

    NSDictionary *baseQuery =
        BaseKeychainQuery(applicationID);

    NSDictionary *attributes = @{
        (__bridge id)kSecValueData:
            data,

        (__bridge id)kSecAttrAccessible:
            (__bridge id)
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    };

    OSStatus status =
        SecItemUpdate(
            (__bridge CFDictionaryRef)baseQuery,
            (__bridge CFDictionaryRef)attributes
        );

    if (status == errSecItemNotFound) {

        NSMutableDictionary *newItem =
            [baseQuery mutableCopy];

        [
            newItem
            addEntriesFromDictionary:attributes
        ];

        status =
            SecItemAdd(
                (__bridge CFDictionaryRef)newItem,
                NULL
            );
    }

    return status == errSecSuccess;
}


static void DeleteTokenPayload(
    uint64_t applicationID
) {
    NSDictionary *query =
        BaseKeychainQuery(applicationID);

    SecItemDelete(
        (__bridge CFDictionaryRef)query
    );
}

} // namespace


@interface DiscordBridge ()

- (void)notifyReady:(BOOL)ready
               text:(NSString *)text;

- (void)ensureClient;

- (void)loadStoredTokensIfNeeded;

- (void)saveTokensWithAccessToken:(NSString *)accessToken
                     refreshToken:(NSString *)refreshToken
                        expiresIn:(int32_t)expiresIn;

- (void)clearStoredTokens;

- (BOOL)shouldRefreshToken;

- (void)applyStoredAccessTokenAndConnect;

- (void)refreshStoredToken;

- (void)scheduleRefreshRetry:(NSTimeInterval)delay;

- (void)beginAuthorization;

- (void)sendPendingPresenceIfPossible;

@end


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

    static DiscordBridge *instance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(
        &onceToken,
        ^{
            instance =
                [[DiscordBridge alloc] init];
        }
    );

    return instance;
}


// MARK: - Init


- (instancetype)init {

    self = [super init];

    if (self) {

        _applicationID = 0;

        _tokensLoadedForApplicationID = 0;

        _authorizationRunning = NO;

        _tokenOperationRunning = NO;

        _ready = NO;

        _accessTokenExpiresAt = 0;
    }

    return self;
}


// MARK: - Status


- (void)notifyReady:(BOOL)ready
               text:(NSString *)text {

    _ready = ready;

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


// MARK: - Client


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


            // Ready

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


            // Connecting

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


            // Connected

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


            // Reconnecting

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


            // Disconnecting

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


            // HTTP wait

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


            // Disconnected

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
                            ErrorToString(error);

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


    // Token expiry

    _client->SetTokenExpirationCallback(

        [weakSelf]() {

            DiscordBridge *selfRef =
                weakSelf;

            if (!selfRef) {
                return;
            }

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


// MARK: - Keychain Load


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

    _accessTokenExpiresAt = 0;

    NSDictionary *payload =
        LoadTokenPayload(
            _applicationID
        );

    if (!payload) {
        return;
    }

    NSString *accessToken =
        payload[@"accessToken"];

    NSString *refreshToken =
        payload[@"refreshToken"];

    NSNumber *expiresAt =
        payload[@"expiresAt"];


    if (
        [accessToken
            isKindOfClass:[NSString class]
        ]
    ) {

        _accessToken =
            NSStringToString(accessToken);
    }


    if (
        [refreshToken
            isKindOfClass:[NSString class]
        ]
    ) {

        _refreshToken =
            NSStringToString(refreshToken);
    }


    if (
        [expiresAt
            isKindOfClass:[NSNumber class]
        ]
    ) {

        _accessTokenExpiresAt =
            expiresAt.doubleValue;
    }
}


// MARK: - Keychain Save


- (void)saveTokensWithAccessToken:(NSString *)accessToken
                     refreshToken:(NSString *)refreshToken
                        expiresIn:(int32_t)expiresIn {

    if (_applicationID == 0) {
        return;
    }

    _accessToken =
        NSStringToString(accessToken);

    _refreshToken =
        NSStringToString(refreshToken);

    NSTimeInterval now =
        [NSDate date]
            .timeIntervalSince1970;

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
            @(_accessTokenExpiresAt)
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


// MARK: - Delete Tokens


- (void)clearStoredTokens {

    if (_applicationID != 0) {

        DeleteTokenPayload(
            _applicationID
        );
    }

    _accessToken.clear();

    _refreshToken.clear();

    _accessTokenExpiresAt = 0;
}


// MARK: - Token State


- (BOOL)shouldRefreshToken {

    if (_refreshToken.empty()) {
        return NO;
    }

    if (_accessToken.empty()) {
        return YES;
    }

    if (_accessTokenExpiresAt <= 0) {
        return YES;
    }

    NSTimeInterval now =
        [NSDate date]
            .timeIntervalSince1970;

    const double refreshWindow =
        24.0 *
        60.0 *
        60.0;

    return
        _accessTokenExpiresAt <=
        now + refreshWindow;
}


// MARK: - Start


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


    [self ensureClient];


    _client->SetApplicationId(
        applicationID
    );


    [self loadStoredTokensIfNeeded];


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


    if ([self shouldRefreshToken]) {

        [self refreshStoredToken];

        return;
    }


    if (!_accessToken.empty()) {

        [self
            applyStoredAccessTokenAndConnect
        ];

        return;
    }


    if (!_refreshToken.empty()) {

        [self refreshStoredToken];

        return;
    }


    [self beginAuthorization];
}


// MARK: - Restore Access Token


- (void)applyStoredAccessTokenAndConnect {

    if (!_client ||
        _accessToken.empty()) {

        return;
    }


    if (_tokenOperationRunning) {
        return;
    }


    _tokenOperationRunning = YES;


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


// MARK: - Refresh Token


- (void)refreshStoredToken {

    if (!_client ||
        _applicationID == 0) {

        return;
    }


    if (
        _tokenOperationRunning ||
        _authorizationRunning
    ) {

        return;
    }


    [self loadStoredTokensIfNeeded];


    if (_refreshToken.empty()) {

        [self beginAuthorization];

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


            if (!result.Successful()) {

                NSLog(
                    @"Discord RefreshToken failed: %s",
                    result.Error().c_str()
                );


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


                [selfRef clearStoredTokens];


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


            if (
                accessToken.empty() ||
                refreshToken.empty()
            ) {

                [selfRef clearStoredTokens];


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
                        Client::Status status =
                            self2->
                                _client->
                                GetStatus();


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


// MARK: - Refresh Retry


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


// MARK: - Initial Authorization


- (void)beginAuthorization {

    if (!_client ||
        _applicationID == 0) {

        return;
    }


    if (
        _authorizationRunning ||
        _tokenOperationRunning
    ) {

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
                    discordpp::ClientResult tokenResult,
                    std::string accessToken,
                    std::string refreshToken,
                    discordpp::AuthorizationTokenType tokenType,
                    int32_t expiresIn,
                    std::string scopes
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
                            discordpp::ClientResult
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


// MARK: - Reconnect


- (void)reconnectIfNeeded {

    if (!_client ||
        _applicationID == 0) {

        return;
    }


    discordpp::Client::Status status =
        _client->GetStatus();


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


    [self loadStoredTokensIfNeeded];


    if ([self shouldRefreshToken]) {

        [self refreshStoredToken];

        return;
    }


    if (_client->IsAuthenticated()) {

        [self
            notifyReady:NO
            text:@"Discord 再接続中"
        ];


        _client->Connect();

        return;
    }


    if (!_accessToken.empty()) {

        [self
            applyStoredAccessTokenAndConnect
        ];

        return;
    }


    if (!_refreshToken.empty()) {

        [self refreshStoredToken];

        return;
    }


    [self beginAuthorization];
}


// MARK: - Callbacks


- (void)runCallbacks {

    discordpp::RunCallbacks();
}


// MARK: - Update Presence


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
     Discord切断中でも
     最新の曲を保持する。
     */
    _pendingPresence.valid =
        true;


    _pendingPresence.title =
        NSStringToString(title);


    _pendingPresence.artist =
        NSStringToString(artist);


    _pendingPresence.album =
        NSStringToString(album);


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


// MARK: - Send Presence


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


    /*
     Listening
     */
    activity.SetType(
        discordpp::
            ActivityTypes::Listening
    );


    /*
     超重要。

     デフォルトではDiscordの
     アプリ名 / SDK名がステータスに使われる。

     Detailsを指定して、
     下のSetDetailsに入れている曲名を
     ステータスとして使わせる。
     */
    activity.SetStatusDisplayType(
        discordpp::
            StatusDisplayTypes::Details
    );


    /*
     曲名
     */
    activity.SetDetails(
        presence.title
    );


    /*
     アーティスト
     */
    activity.SetState(
        presence.artist
    );


    /*
     曲名タップ → Apple Music
     */
    if (
        presence.songURL.has_value()
    ) {

        activity.SetDetailsUrl(
            presence.songURL.value()
        );
    }


    // MARK: - Timestamps


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


    // MARK: - Artwork


    discordpp::ActivityAssets
        assets;


    if (
        presence.artworkURL.has_value()
    ) {

        /*
         Apple Musicの
         実ジャケットURL
         */
        assets.SetLargeImage(
            presence.artworkURL.value()
        );

    } else {

        /*
         Artworkが本当に取得不能な時だけ
         Developer Portalのassetへfallback
         */
        assets.SetLargeImage(
            "applemusic"
        );
    }


    /*
     アルバム名
     */
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


    /*
     ジャケットタップ
     → Apple Music
     */
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
                 pendingPresenceは消さない。

                 再接続したら
                 現在曲をもう一度送る。
                 */
                [selfRef
                    notifyReady:NO
                    text:@"Presence 再送待ち"
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


// MARK: - Clear Presence


- (void)clearPresence {

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
