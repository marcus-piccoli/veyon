#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VNC = ROOT / "core" / "src" / "VncConnection.cpp"
CMAKE = ROOT / "core" / "CMakeLists.txt"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


vnc = VNC.read_text(encoding="utf-8")

vnc = replace_once(
    vnc,
    '#include <rfb/rfbclient.h>\n\n#include <cstdio>',
    '#ifdef _WIN32\n'
    '#include <winsock2.h>\n'
    '#include <ws2tcpip.h>\n'
    '#include <windns.h>\n'
    '#endif\n\n'
    '#include <rfb/rfbclient.h>\n\n#include <cstdio>',
    "Windows DNS includes",
)

vnc = replace_once(
    vnc,
    '#include <QRegularExpression>\n#include <QTime>',
    '#include <QRegularExpression>\n#include <QStringList>\n#include <QTime>',
    "QStringList include",
)

resolver = r'''#ifdef _WIN32
static QStringList resolveFreshIpv4Addresses( const QString& host )
{
	QHostAddress literalAddress( host );
	if( literalAddress.protocol() == QAbstractSocket::IPv4Protocol )
	{
		return { literalAddress.toString() };
	}

	PDNS_RECORDW records = nullptr;
	const auto status = DnsQuery_W( reinterpret_cast<PCWSTR>( host.utf16() ),
								 DNS_TYPE_A,
								 DNS_QUERY_BYPASS_CACHE,
								 nullptr,
								 &records,
								 nullptr );

	if( status != ERROR_SUCCESS )
	{
		vDebug() << "Veyon Fix fresh DNS lookup failed for" << host << "status" << status;
		return {};
	}

	QStringList addresses;
	for( auto record = records; record != nullptr; record = record->pNext )
	{
		if( record->wType == DNS_TYPE_A )
		{
			IN_ADDR nativeAddress{};
			nativeAddress.s_addr = record->Data.A.IpAddress;

			char addressBuffer[INET_ADDRSTRLEN]{};
			if( inet_ntop( AF_INET, &nativeAddress, addressBuffer, sizeof(addressBuffer) ) != nullptr )
			{
				addresses.append( QString::fromLatin1(addressBuffer) );
			}
		}
	}

	DnsRecordListFree( records, DnsFreeRecordList );
	addresses.removeDuplicates();
	return addresses;
}
#endif
'''

vnc = replace_once(
    vnc,
    '#include "VncEvents.h"\n\n\nrfbBool VncConnection::hookInitFrameBuffer',
    '#include "VncEvents.h"\n\n\n' + resolver + '\nrfbBool VncConnection::hookInitFrameBuffer',
    "fresh DNS resolver insertion",
)

vnc = replace_once(
    vnc,
    'void VncConnection::establishConnection()\n{\n\tQMutex sleeperMutex;',
    'void VncConnection::establishConnection()\n{\n\tQMutex sleeperMutex;\n\tint freshDnsAddressIndex = 0;',
    "DNS retry index",
)

connection_resolution = r'''		QString configuredHost;
		{
			QMutexLocker locker( &m_globalMutex );
			configuredHost = m_host;
		}

		QString connectionHost = configuredHost;
#ifdef _WIN32
		const auto freshAddresses = resolveFreshIpv4Addresses( configuredHost );
		if( freshAddresses.isEmpty() == false )
		{
			connectionHost = freshAddresses.at( freshDnsAddressIndex % int(freshAddresses.size()) );
			++freshDnsAddressIndex;
			vDebug() << "Veyon Fix fresh DNS:" << configuredHost << "->" << freshAddresses
					 << "using" << connectionHost;
		}
		else
		{
			vDebug() << "Veyon Fix fresh DNS: falling back to configured host" << configuredHost;
		}
#endif
'''

vnc = replace_once(
    vnc,
    '\t\tQ_EMIT connectionPrepared();\n\n\t\tm_globalMutex.lock();',
    '\t\tQ_EMIT connectionPrepared();\n\n' + connection_resolution + '\n\t\tm_globalMutex.lock();',
    "per-attempt fresh DNS resolution",
)

vnc = replace_once(
    vnc,
    '\t\tm_client->serverHost = strdup( m_host.toUtf8().constData() );',
    '\t\tm_client->serverHost = strdup( connectionHost.toUtf8().constData() );',
    "VNC connection target",
)

vnc = replace_once(
    vnc,
    '\t\t\t\t\tconst auto pingResult = VeyonCore::platform().networkFunctions().ping(m_host);',
    '\t\t\t\t\tconst auto pingResult = VeyonCore::platform().networkFunctions().ping(connectionHost);',
    "connection diagnostic ping target",
)

VNC.write_text(vnc, encoding="utf-8")

cmake = CMAKE.read_text(encoding="utf-8")
cmake = replace_once(
    cmake,
    '\ttarget_link_libraries(veyon-core PRIVATE -lws2_32)',
    '\t# dnsapi is required by the Veyon Fix fresh DNS resolver\n'
    '\ttarget_link_libraries(veyon-core PRIVATE -lws2_32 -ldnsapi)',
    "dnsapi linker dependency",
)
CMAKE.write_text(cmake, encoding="utf-8")

print("Veyon Fix fresh DNS source changes applied successfully")
