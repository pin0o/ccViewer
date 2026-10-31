//
//  Secret.swift
//  RemoteCloud
//
//  Created by rei8 on 2019/04/26.
//  Copyright © 2019 lithium03. All rights reserved.
//

import Foundation

/// Separate credentials even if a signing tool grants a shared Keychain group.
public enum PoCAppIdentity {
    public static let keychainService = "io.github.pin0o.ccViewerPoC"
}

class SecretItems {
    public class Google {
        public static let callbackUrlScheme = "com.googleusercontent.apps.391464667029-b4dvg0kesr6hjs3lani2i7m9jjh8nq5g"
        public static let client_id = "391464667029-b4dvg0kesr6hjs3lani2i7m9jjh8nq5g.apps.googleusercontent.com"
    }
    public class Dropbox {
        public static let client_id = ""
        public static let callbackUrlScheme = "io.github.pin0o.ccviewer-poc.dropbox"
    }
    public class OneDrive {
        public static let client_id = ""
        public static let callbackUrlScheme = "io.github.pin0o.ccviewer-poc.onedrive"
    }
    public class pCloud {
        public static let callbackUrlScheme = "io.github.pin0o.ccviewer-poc.pcloud"
        public static let client_id = ""
        public static let client_secret = ""
    }
}
