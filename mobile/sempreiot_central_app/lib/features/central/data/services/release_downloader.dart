import 'dart:typed_data';

import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../iot/data/services/iot_credentials_service.dart';
import '../../application/central_iot_provider.dart';

/// Fetches a published firmware image (docs/ota/ota-internet-plan.md D3).
abstract class ReleaseDownloader {
  /// The bytes of object [key] in [bucket]. Throws [ReleaseDownloadException]
  /// with a text for the operator.
  Future<Uint8List> download({
    required String bucket,
    required String region,
    required String key,
  });
}

class ReleaseDownloadException implements Exception {
  const ReleaseDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// GET from the private bucket, signed (SigV4) with the central's own
/// identity-pool credentials — the same ones its MQTT session uses. The
/// role grants each central the channel folders and its own
/// `centrals/<Identity ID>/` folder only (`tools/ota_cloud_setup.sh`).
class S3ReleaseDownloader implements ReleaseDownloader {
  S3ReleaseDownloader(this._credentials, {http.Client? client})
      : _client = client ?? http.Client();

  final Future<AwsCredentials> Function() _credentials;
  final http.Client _client;

  static const _timeout = Duration(seconds: 60);

  @override
  Future<Uint8List> download({
    required String bucket,
    required String region,
    required String key,
  }) async {
    final AwsCredentials creds;
    try {
      creds = await _credentials();
    } catch (e) {
      throw ReleaseDownloadException('Sem credenciais da nuvem: $e');
    }
    final signer = AWSSigV4Signer(
      credentialsProvider: AWSCredentialsProvider(AWSCredentials(
          creds.accessKeyId, creds.secretAccessKey, creds.sessionToken)),
    );
    final request = AWSHttpRequest.get(
        Uri.https('$bucket.s3.$region.amazonaws.com', '/$key'));
    final signed = await signer.sign(
      request,
      credentialScope: AWSCredentialScope(region: region, service: AWSService.s3),
      serviceConfiguration: S3ServiceConfiguration(),
    );
    final http.Response res;
    try {
      res = await _client
          .get(signed.uri, headers: signed.headers)
          .timeout(_timeout);
    } catch (e) {
      throw ReleaseDownloadException('Falha ao baixar o firmware: $e');
    }
    if (res.statusCode == 403 || res.statusCode == 404) {
      throw ReleaseDownloadException(
          'Firmware não encontrado na nuvem (${res.statusCode}).');
    }
    if (res.statusCode != 200) {
      throw ReleaseDownloadException(
          'A nuvem respondeu ${res.statusCode} ao baixar o firmware.');
    }
    return res.bodyBytes;
  }
}

final releaseDownloaderProvider = Provider<ReleaseDownloader>(
  (ref) => S3ReleaseDownloader(
      () => ref.read(centralCredentialsServiceProvider).fetch()),
);
