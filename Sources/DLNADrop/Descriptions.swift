import Foundation

enum Descriptions {
    static func device(uuid: String, name: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <device>
            <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
            <friendlyName>\(XML.escape(name))</friendlyName>
            <manufacturer>DLNA Drop</manufacturer>
            <modelDescription>DLNA Drop media server</modelDescription>
            <modelName>DLNA Drop</modelName>
            <modelNumber>1.0</modelNumber>
            <UDN>uuid:\(uuid)</UDN>
            <dlna:X_DLNADOC>DMS-1.50</dlna:X_DLNADOC>
            <iconList>
              <icon><mimetype>image/png</mimetype><width>256</width><height>256</height><depth>24</depth><url>/icon.png</url></icon>
            </iconList>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
                <serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>
                <SCPDURL>/cds.xml</SCPDURL>
                <controlURL>/control/cds</controlURL>
                <eventSubURL>/event/cds</eventSubURL>
              </service>
              <service>
                <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
                <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
                <SCPDURL>/cms.xml</SCPDURL>
                <controlURL>/control/cms</controlURL>
                <eventSubURL>/event/cms</eventSubURL>
              </service>
              <service>
                <serviceType>urn:microsoft.com:service:X_MS_MediaReceiverRegistrar:1</serviceType>
                <serviceId>urn:microsoft.com:serviceId:X_MS_MediaReceiverRegistrar</serviceId>
                <SCPDURL>/mrr.xml</SCPDURL>
                <controlURL>/control/mrr</controlURL>
                <eventSubURL>/event/mrr</eventSubURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
    }

    private static func scpd(actions: String, variables: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <actionList>\(actions)</actionList>
          <serviceStateTable>\(variables)</serviceStateTable>
        </scpd>
        """
    }

    private static func action(_ name: String, _ args: [(String, String, String)]) -> String {
        let list = args.map {
            "<argument><name>\($0.0)</name><direction>\($0.1)</direction><relatedStateVariable>\($0.2)</relatedStateVariable></argument>"
        }.joined()
        return "<action><name>\(name)</name><argumentList>\(list)</argumentList></action>"
    }

    private static func variable(_ name: String, _ type: String, events: Bool = false, allowed: [String] = []) -> String {
        let values = allowed.isEmpty ? "" :
            "<allowedValueList>" + allowed.map { "<allowedValue>\($0)</allowedValue>" }.joined() + "</allowedValueList>"
        return "<stateVariable sendEvents=\"\(events ? "yes" : "no")\"><name>\(name)</name><dataType>\(type)</dataType>\(values)</stateVariable>"
    }

    static let contentDirectorySCPD = scpd(
        actions: [
            action("Browse", [
                ("ObjectID", "in", "A_ARG_TYPE_ObjectID"), ("BrowseFlag", "in", "A_ARG_TYPE_BrowseFlag"),
                ("Filter", "in", "A_ARG_TYPE_Filter"), ("StartingIndex", "in", "A_ARG_TYPE_Index"),
                ("RequestedCount", "in", "A_ARG_TYPE_Count"), ("SortCriteria", "in", "A_ARG_TYPE_SortCriteria"),
                ("Result", "out", "A_ARG_TYPE_Result"), ("NumberReturned", "out", "A_ARG_TYPE_Count"),
                ("TotalMatches", "out", "A_ARG_TYPE_Count"), ("UpdateID", "out", "A_ARG_TYPE_UpdateID"),
            ]),
            action("GetSearchCapabilities", [("SearchCaps", "out", "SearchCapabilities")]),
            action("GetSortCapabilities", [("SortCaps", "out", "SortCapabilities")]),
            action("GetSystemUpdateID", [("Id", "out", "SystemUpdateID")]),
            action("X_GetFeatureList", [("FeatureList", "out", "A_ARG_TYPE_Featurelist")]),
        ].joined(),
        variables: [
            variable("A_ARG_TYPE_ObjectID", "string"),
            variable("A_ARG_TYPE_BrowseFlag", "string", allowed: ["BrowseMetadata", "BrowseDirectChildren"]),
            variable("A_ARG_TYPE_Filter", "string"),
            variable("A_ARG_TYPE_Index", "ui4"),
            variable("A_ARG_TYPE_Count", "ui4"),
            variable("A_ARG_TYPE_SortCriteria", "string"),
            variable("A_ARG_TYPE_Result", "string"),
            variable("A_ARG_TYPE_UpdateID", "ui4"),
            variable("A_ARG_TYPE_Featurelist", "string"),
            variable("SearchCapabilities", "string"),
            variable("SortCapabilities", "string"),
            variable("SystemUpdateID", "ui4", events: true),
        ].joined()
    )

    static let connectionManagerSCPD = scpd(
        actions: [
            action("GetProtocolInfo", [("Source", "out", "SourceProtocolInfo"), ("Sink", "out", "SinkProtocolInfo")]),
            action("GetCurrentConnectionIDs", [("ConnectionIDs", "out", "CurrentConnectionIDs")]),
            action("GetCurrentConnectionInfo", [
                ("ConnectionID", "in", "A_ARG_TYPE_ConnectionID"), ("RcsID", "out", "A_ARG_TYPE_RcsID"),
                ("AVTransportID", "out", "A_ARG_TYPE_AVTransportID"), ("ProtocolInfo", "out", "A_ARG_TYPE_ProtocolInfo"),
                ("PeerConnectionManager", "out", "A_ARG_TYPE_ConnectionManager"),
                ("PeerConnectionID", "out", "A_ARG_TYPE_ConnectionID"), ("Direction", "out", "A_ARG_TYPE_Direction"),
                ("Status", "out", "A_ARG_TYPE_ConnectionStatus"),
            ]),
        ].joined(),
        variables: [
            variable("SourceProtocolInfo", "string", events: true),
            variable("SinkProtocolInfo", "string", events: true),
            variable("CurrentConnectionIDs", "string", events: true),
            variable("A_ARG_TYPE_ConnectionStatus", "string", allowed: ["OK", "ContentFormatMismatch", "InsufficientBandwidth", "UnreliableChannel", "Unknown"]),
            variable("A_ARG_TYPE_ConnectionManager", "string"),
            variable("A_ARG_TYPE_Direction", "string", allowed: ["Input", "Output"]),
            variable("A_ARG_TYPE_ProtocolInfo", "string"),
            variable("A_ARG_TYPE_ConnectionID", "i4"),
            variable("A_ARG_TYPE_AVTransportID", "i4"),
            variable("A_ARG_TYPE_RcsID", "i4"),
        ].joined()
    )

    static let registrarSCPD = scpd(
        actions: [
            action("IsAuthorized", [("DeviceID", "in", "A_ARG_TYPE_DeviceID"), ("Result", "out", "A_ARG_TYPE_Result")]),
            action("IsValidated", [("DeviceID", "in", "A_ARG_TYPE_DeviceID"), ("Result", "out", "A_ARG_TYPE_Result")]),
            action("RegisterDevice", [
                ("RegistrationReqMsg", "in", "A_ARG_TYPE_RegistrationReqMsg"),
                ("RegistrationRespMsg", "out", "A_ARG_TYPE_RegistrationRespMsg"),
            ]),
        ].joined(),
        variables: [
            variable("A_ARG_TYPE_DeviceID", "string"),
            variable("A_ARG_TYPE_Result", "int"),
            variable("A_ARG_TYPE_RegistrationReqMsg", "bin.base64"),
            variable("A_ARG_TYPE_RegistrationRespMsg", "bin.base64"),
            variable("AuthorizationGrantedUpdateID", "ui4", events: true),
            variable("AuthorizationDeniedUpdateID", "ui4", events: true),
            variable("ValidationSucceededUpdateID", "ui4", events: true),
            variable("ValidationRevokedUpdateID", "ui4", events: true),
        ].joined()
    )
}
