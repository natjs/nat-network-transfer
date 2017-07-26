package com.nat.transfer;

import android.content.res.AssetFileDescriptor;
import android.net.Uri;
import android.os.Environment;
import android.text.TextUtils;
import android.webkit.MimeTypeMap;

import com.alibaba.fastjson.JSON;
import com.alibaba.fastjson.JSONObject;

import org.json.JSONArray;
import org.json.JSONException;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.FileNameMap;
import java.net.HttpURLConnection;
import java.net.MalformedURLException;
import java.net.ProtocolException;
import java.net.URL;
import java.net.URLConnection;
import java.security.NoSuchAlgorithmException;
import java.util.Date;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.GZIPInputStream;
import java.util.zip.Inflater;

/**
 * Created by xuqinchao on 17/1/23.
 *  Copyright (c) 2017 Instapp. All rights reserved.
 */

public class TransferModule {

    private static final int MAX_BUFFER_SIZE = 16 * 1024;
    private static final String LINE_START = "--";
    private static final String LINE_END = "\r\n";
    private final ThreadPoolExecutor mThreadPool;
    private String BOUNDARY;

    //upload
    private String url;
    private String path;
    private String name;
    private String mimeType;
    private String method;
    private JSONObject headers;
    private JSONObject formData;

    private static volatile TransferModule instance = null;

    private TransferModule(){
        mThreadPool = new ThreadPoolExecutor(10, 20, 3, TimeUnit.SECONDS, new ArrayBlockingQueue<Runnable>(3),
                new ThreadPoolExecutor.DiscardOldestPolicy());
    }

    public static TransferModule getInstance() {
        if (instance == null) {
            synchronized (TransferModule.class) {
                if (instance == null) {
                    instance = new TransferModule();
                }
            }
        }

        return instance;
    }

    public void download(String s, final ModuleResultListener listener) {
        JSONObject args = null;
        args = JSON.parseObject(s);

        try {
            BOUNDARY = Util.getMD5("nat" + new Date().getTime());
        } catch (NoSuchAlgorithmException e) {
            e.printStackTrace();
            BOUNDARY = "nat+++++";
        }

        String url = "";
        String target = "";
        String name = null;
        JSONObject header = null;

        url = args.getString("url");
        header = args.getJSONObject("headers");
        target = args.containsKey("target") ? args.getString("target") : "/Instapp/download";
        name = args.containsKey("name") ? args.getString("name") : "";

        if (!url.startsWith("http://") && !url.startsWith("https://")) {
            listener.onResult(Util.getError(Constant.DOWNLOAD_INVALID_ARGUMENT, Constant.DOWNLOAD_INVALID_ARGUMENT_CODE));
            return;
        }

        final Uri urlUri = Uri.parse(url);
        final JSONObject headers = header;
        final Uri targetUri = Uri.parse(target);
        final Uri fileNameUri = Uri.parse(name);

        mThreadPool.execute(new Runnable() {
            @Override
            public void run() {
                TrackingInputStream inputStream = null;
                OutputStream outputStream = null;
                HttpURLConnection connection = null;

                try {
                    FileProgressResult progress = new FileProgressResult();
                    connection = (HttpURLConnection) new URL(urlUri.toString()).openConnection();
                    connection.setRequestMethod("GET");
                    connection.setRequestProperty("Accept-Encoding", "gzip");

                    if (headers != null) {
                        addHeadersToRequest(connection, headers);
                    }

                    connection.connect();

                    if (connection.getResponseCode() == HttpURLConnection.HTTP_NOT_MODIFIED) {
                        // TODO: 17/2/8 Resource not modified: source
                        listener.onResult(Util.getError("Resource not modified: ", 1));
                        return;
                    } else {
                        if (connection.getContentEncoding() == null || connection.getContentEncoding().equalsIgnoreCase("gzip")) {
                            if (connection.getContentLength() != -1) {
                                progress.setLengthComputable(true);
                                progress.setTotal(connection.getContentLength());
                            }
                        }
                        inputStream = getInputStream(connection);
                    }

                    HashMap<String, Object> progressResult = new HashMap<String, Object>();
                    File fileFinal = getDownloadFile(targetUri);
                    try {
                        byte[] buffer = new byte[MAX_BUFFER_SIZE];
                        int bytesRead = 0;
                        outputStream = new FileOutputStream(fileFinal);
                        while ((bytesRead = inputStream.read(buffer)) > 0) {
                            outputStream.write(buffer, 0, bytesRead);
                            progress.setLoaded(inputStream.getTotalRawBytesRead());
                            progressResult.put("progress", progress.getLoaded() / (progress.getTotal() + 0.0));
                            listener.onResult(progressResult);
                        }
                    } finally {
                        progressResult.put("progress", 1);
                        listener.onResult(progressResult);
                        safeClose(inputStream);
                        safeClose(outputStream);
                    }

                    HashMap<String, Object> result = new HashMap<String, Object>();
                    int responseCode = connection.getResponseCode();
                    String responseMessage = connection.getResponseMessage();
                    boolean ok = responseCode >= 200 && responseCode <= 299;
                    Map<String, String> responseHeaders = getResponseHeaders(connection);
                    result.put("status", responseCode);
                    result.put("statusText", responseMessage);
                    result.put("ok", ok);
                    if (responseHeaders != null) result.put("headers", responseHeaders);

                    if (!ok && fileFinal.exists()) {
                        fileFinal.delete();
                    }
                    if (ok) renameDownFile(fileFinal, targetUri, urlUri, connection , fileNameUri.getPath());

                    if (connection != null) connection.disconnect();
                    listener.onResult(result);
                } catch (ProtocolException e) {
                    e.printStackTrace();
                    if (connection != null) connection.disconnect();
                    listener.onResult(Util.getError(Constant.DOWNLOAD_INTERNAL_ERROR, Constant.DOWNLOAD_INTERNAL_ERROR_CODE));
                } catch (MalformedURLException e) {
                    e.printStackTrace();
                    if (connection != null) connection.disconnect();
                    listener.onResult(Util.getError(Constant.DOWNLOAD_INVALID_ARGUMENT, Constant.DOWNLOAD_INVALID_ARGUMENT_CODE));
                } catch (IOException e) {
                    e.printStackTrace();
                    if (connection != null) connection.disconnect();
                    listener.onResult(Util.getError(Constant.DOWNLOAD_INTERNAL_ERROR, Constant.DOWNLOAD_INTERNAL_ERROR_CODE));
                }
            }
        });

    }

    public void upload(String s, final ModuleResultListener listener) {
        JSONObject args = null;
        args = JSON.parseObject(s);

        try {
            BOUNDARY = Util.getMD5("nat" + new Date().getTime());
        } catch (NoSuchAlgorithmException e) {
            e.printStackTrace();
            BOUNDARY = "nat+++++";
        }

        url = args.getString("url");
        path = args.getString("path");
        name = args.getString("name");
        mimeType = args.getString("mimeType");
        method = args.containsKey("method") ? args.getString("method") : "POST";
        headers = args.getJSONObject("headers");
        formData = args.getJSONObject("formData");

        if (TextUtils.isEmpty(name)) {
            String[] split = path.split("/");
            if (split.length < 1) {
                listener.onResult(Util.getError(Constant.UPLOAD_INVALID_ARGUMENT, Constant.UPLOAD_INVALID_ARGUMENT_CODE));
                return;
            }
            name = split[split.length - 1];
        }

        if (TextUtils.isEmpty(mimeType)) {
            FileNameMap fileNameMap = URLConnection.getFileNameMap();
            mimeType = fileNameMap.getContentTypeFor("file://" + path);
        }

        if (!url.startsWith("http://") && !url.startsWith("https://")) {
            listener.onResult(Util.getError(Constant.UPLOAD_INVALID_ARGUMENT, Constant.UPLOAD_INVALID_ARGUMENT_CODE));
            return;
        }

        mThreadPool.execute(new Runnable() {
            @Override
            public void run() {
                HttpURLConnection conn = null;
                int totalBytes = 0;
                int fixedLength = -1;

                try {
                    FileProgressResult progress = new FileProgressResult();
//                    FileUploadResult result = new FileUploadResult();
                    conn = (HttpURLConnection) new URL(url).openConnection();
                    conn.setDoInput(true);
                    conn.setDoOutput(true);
                    conn.setUseCaches(false);
                    conn.setRequestMethod(method);

                    // if we specified a Content-Type headers, don't do multipart form upload
                    boolean multipartFormUpload = (headers == null) || !headers.containsKey("Content-Type");
                    if (multipartFormUpload) {
                        conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=" + BOUNDARY);
                    }
                    // Handle the other headers
                    if (headers != null) {
                        addHeadersToRequest(conn, headers);
                    }

                    StringBuilder beforeData = new StringBuilder();
                    if (formData != null) {
                        for (Map.Entry<String, Object> entry : formData.entrySet()) {
                            beforeData.append(LINE_START).append(BOUNDARY).append(LINE_END);
                            beforeData.append("Content-Disposition: form-data; name=\"").append(entry.getKey()).append('"');
                            beforeData.append(LINE_END).append(LINE_END);
                            beforeData.append(entry.getValue());
                            beforeData.append(LINE_END);
                        }
                    }

                    beforeData.append(LINE_START).append(BOUNDARY).append(LINE_END);
                    beforeData.append("Content-Disposition: form-data; name=\"").append("file").append("\";");
                    beforeData.append(" filename=\"").append(name).append('"').append(LINE_END);
                    beforeData.append("Content-Type: ").append(mimeType).append(LINE_END).append(LINE_END);
                    byte[] beforeDataBytes = beforeData.toString().getBytes("UTF-8");
                    byte[] tailParamsBytes = (LINE_END + LINE_START + BOUNDARY + LINE_START + LINE_END).getBytes("UTF-8");

                    int stringLength = beforeDataBytes.length + tailParamsBytes.length;
                    FileInputStream inputStream = new FileInputStream(path);
                    String mimeType = getMimeTypeFromPath(path);
                    long length = inputStream.getChannel().size();
                    OpenForReadResult readResult = new OpenForReadResult(Uri.parse(path), inputStream, mimeType, length, null);
                    if (readResult.length >= 0) {
                        fixedLength = (int) readResult.length;
                        if (multipartFormUpload)
                            fixedLength += stringLength;
                        progress.setLengthComputable(true);
                        progress.setTotal(fixedLength);
                    }

                    conn.setChunkedStreamingMode(MAX_BUFFER_SIZE);
                    // Although setChunkedStreamingMode sets this header, setting it explicitly here works
                    // around an OutOfMemoryException when using https.
                    conn.setRequestProperty("Transfer-Encoding", "chunked");
                    conn.connect();

                    OutputStream sendStream = null;

                    HashMap<String, Object> progressResult = new HashMap<String, Object>();
                    try {
                        sendStream = conn.getOutputStream();
                        if (multipartFormUpload) {
                            //We don't want to change encoding, we just want this to write for all Unicode.
                            sendStream.write(beforeDataBytes);
                            totalBytes += beforeDataBytes.length;
                        }

                        // create a buffer of maximum size
                        int bytesAvailable = readResult.inputStream.available();
                        int bufferSize = Math.min(bytesAvailable, MAX_BUFFER_SIZE);
                        byte[] buffer = new byte[bufferSize];

                        // read file and write it into form...
                        int bytesRead = readResult.inputStream.read(buffer, 0, bufferSize);
                        long prevBytesRead = 0;

                        while (bytesRead > 0) {
                            totalBytes += bytesRead;
//                            result.setBytesSent(totalBytes);
                            sendStream.write(buffer, 0, bytesRead);
                            if (totalBytes > prevBytesRead + 102400) {
                                prevBytesRead = totalBytes;
                            }
                            bytesAvailable = readResult.inputStream.available();
                            bufferSize = Math.min(bytesAvailable, MAX_BUFFER_SIZE);
                            bytesRead = readResult.inputStream.read(buffer, 0, bufferSize);

                            // Send a progress event.
                            progress.setLoaded(totalBytes);
                            progressResult.put("progress", progress.getLoaded() / (progress.getTotal() + 0.0));
                            listener.onResult(progressResult);
                        }

                        if (multipartFormUpload) {
                            // send multipart form data necessary after file data...
                            sendStream.write(tailParamsBytes);
                            totalBytes += tailParamsBytes.length;
                        }
                        sendStream.flush();
                    } finally {
                        safeClose(readResult.inputStream);
                        safeClose(sendStream);
                        progressResult.put("progress", 1);
                        listener.onResult(progressResult);
                    }

                    String responseString;
                    TrackingInputStream inStream = null;

                    try {
                        inStream = getInputStream(conn);

                        ByteArrayOutputStream out = new ByteArrayOutputStream(Math.max(1024, conn.getContentLength()));
                        byte[] buffer = new byte[1024];
                        int bytesRead = 0;
                        // write bytes to file
                        while ((bytesRead = inStream.read(buffer)) > 0) {
                            out.write(buffer, 0, bytesRead);
                        }
                        responseString = out.toString("UTF-8");
                    } finally {
                        safeClose(inStream);
                    }
                    int responseCode = conn.getResponseCode();
                    String responseMessage = conn.getResponseMessage();
                    boolean ok = responseCode >= 200 && responseCode <= 299;
                    Map<String, String> responseHeaders = getResponseHeaders(conn);
                    HashMap<String, Object> result = new HashMap<String, Object>();
                    result.put("status", responseCode);
                    result.put("statusText", responseMessage);
                    result.put("ok", ok);
                    if (!TextUtils.isEmpty(responseString))result.put("data", responseString);
                    if (responseHeaders != null) result.put("headers", responseHeaders);
                    if (conn != null) conn.disconnect();
                    listener.onResult(result);
                } catch (IOException e) {
                    e.printStackTrace();
                    if (conn != null) conn.disconnect();
                    listener.onResult(Util.getError(Constant.UPLOAD_INTERNAL_ERROR, Constant.UPLOAD_INTERNAL_ERROR_CODE));
                }
            }
        });
    }

    private Map<String,String> getResponseHeaders(HttpURLConnection connection){
        if (connection == null) return null;
        Map<String, List<String>> headers = connection.getHeaderFields();
        Iterator<Map.Entry<String,List<String>>> it = headers.entrySet().iterator();
        Map<String,String> simpleHeaders = new HashMap<>();
        while(it.hasNext()){
            Map.Entry<String,List<String>> entry = it.next();
            if(entry.getValue().size()>0)
                simpleHeaders.put(entry.getKey()==null?"_":entry.getKey(),entry.getValue().get(0));
        }
        return simpleHeaders;
    }

    private String getMimeTypeFromPath(String path) {
        String extension = path;
        int lastDot = extension.lastIndexOf('.');
        if (lastDot != -1) {
            extension = extension.substring(lastDot + 1);
        }
        extension = extension.toLowerCase(Locale.getDefault());
        if (extension.equals("3ga")) {
            return "audio/3gpp";
        } else if (extension.equals("js")) {
            // Missing from the map :(.
            return "text/javascript";
        }
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension);
    }

    private File getDownloadFile(Uri targetUri) throws IOException {
        String fileName;
        Random random = new Random();
        float v = random.nextFloat();
        try {
            fileName = Util.getMD5("nat/transfer/download" + System.currentTimeMillis()) + v;
        } catch (NoSuchAlgorithmException e) {
            e.printStackTrace();
            fileName = "nat/transfer/download" + System.currentTimeMillis() + v;
        }
        File parentFile = new File(Environment.getExternalStorageDirectory().getAbsolutePath() + targetUri.getPath());
        if (!parentFile.exists()) parentFile.mkdirs();

        return new File(parentFile, fileName);
    }

    private void renameDownFile(File downloadFile, Uri targetUri, Uri urlUri, HttpURLConnection connection, String name){
        if (downloadFile == null) return;
        String fileName;
        if (TextUtils.isEmpty(name)) {
            if (targetUri == null || urlUri == null || connection == null) return;
            String[] split1 = urlUri.toString().split("/");
            fileName = split1[split1.length - 1];
            String headerField = connection.getHeaderField("Content-Disposition");
            if (headerField != null) {
                String[] split = headerField.split("=");
                if (split.length > 1) {
                    fileName = split[1].replace("\"", "");
                }
            }
        } else {
            fileName = name;
        }

        int count = 1;
        if (downloadFile.getParent() == null) return;
        File finalFile = new File(downloadFile.getParent(), fileName);
        Pattern pattern = Pattern.compile("(.*)(\\.\\w+)$");
        Matcher matcher = pattern.matcher(fileName);
        boolean matches = matcher.matches();
        String tempFinalName = "";
        while (finalFile.exists()) {
            if (matches) {
                int i = fileName.lastIndexOf(".");
                StringBuffer stringBuffer = new StringBuffer(fileName);
                stringBuffer.insert(i, "(" + count + ")");
                tempFinalName = stringBuffer.toString();
            } else {
                tempFinalName = fileName + "(" + count + ")";
            }
            finalFile = new File(downloadFile.getParent(), tempFinalName);
            count++;
        }

        downloadFile.renameTo(finalFile);
    }

    private static void addHeadersToRequest(URLConnection connection, JSONObject headers) {
        try {
            for (Map.Entry<String, Object> entry : headers.entrySet()) {
                String headerKey = entry.getKey();
                String cleanHeaderKey = headerKey.replaceAll("\\n", "")
                        .replaceAll("\\s+", "")
                        .replaceAll(":", "")
                        .replaceAll("[^\\x20-\\x7E]+", "");

                JSONArray headerValues = new JSONArray();
                if (headerValues == null) {
                    headerValues = new JSONArray();
                    String headerValue = null;
                    String finalValue = headerValue.replaceAll("\\s+", " ").replaceAll("\\n", " ").replaceAll("[^\\x20-\\x7E]+", " ");
                    headerValues.put(finalValue);
                }

                connection.setRequestProperty(cleanHeaderKey, headerValues.getString(0));
                for (int i = 1; i < headerValues.length(); ++i) {
                    connection.addRequestProperty(headerKey, headerValues.getString(i));
                }
            }
        } catch (JSONException e1) {
            // No headers to be manipulated!
        }
    }

    private static TrackingInputStream getInputStream(URLConnection conn) throws IOException {
        String encoding = conn.getContentEncoding();
        if (encoding != null && encoding.equalsIgnoreCase("gzip")) {
            return new TrackingGZIPInputStream(new ExposedGZIPInputStream(conn.getInputStream()));
        }
        return new SimpleTrackingInputStream(conn.getInputStream());
    }

    /**
     * Provides raw bytes-read tracking for a GZIP input stream. Reports the
     * total number of compressed bytes read from the input, rather than the
     * number of uncompressed bytes.
     */
    private static class TrackingGZIPInputStream extends TrackingInputStream {
        private ExposedGZIPInputStream gzin;

        public TrackingGZIPInputStream(final ExposedGZIPInputStream gzin) throws IOException {
            super(gzin);
            this.gzin = gzin;
        }

        public long getTotalRawBytesRead() {
            return gzin.getInflater().getBytesRead();
        }
    }

    private static class ExposedGZIPInputStream extends GZIPInputStream {
        public ExposedGZIPInputStream(final InputStream in) throws IOException {
            super(in);
        }

        public Inflater getInflater() {
            return inf;
        }
    }

    /**
     * Provides simple total-bytes-read tracking for an existing InputStream
     */
    private static class SimpleTrackingInputStream extends TrackingInputStream {
        private long bytesRead = 0;

        public SimpleTrackingInputStream(InputStream stream) {
            super(stream);
        }

        private int updateBytesRead(int newBytesRead) {
            if (newBytesRead != -1) {
                bytesRead += newBytesRead;
            }
            return newBytesRead;
        }

        @Override
        public int read() throws IOException {
            return updateBytesRead(super.read());
        }

        // Note: FilterInputStream delegates read(byte[] bytes) to the below method,
        // so we don't override it or else double count (CB-5631).
        @Override
        public int read(byte[] bytes, int offset, int count) throws IOException {
            return updateBytesRead(super.read(bytes, offset, count));
        }

        public long getTotalRawBytesRead() {
            return bytesRead;
        }
    }

    /**
     * Adds an interface method to an InputStream to return the number of bytes
     * read from the raw stream. This is used to track total progress against
     * the HTTP Content-Length header value from the server.
     */
    private static abstract class TrackingInputStream extends FilterInputStream {
        public TrackingInputStream(final InputStream in) {
            super(in);
        }

        public abstract long getTotalRawBytesRead();
    }

    private static void safeClose(Closeable stream) {
        if (stream != null) {
            try {
                stream.close();
            } catch (IOException e) {
            }
        }
    }

    public static final class OpenForReadResult {
        public final Uri uri;
        public final InputStream inputStream;
        public final String mimeType;
        public final long length;
        public final AssetFileDescriptor assetFd;

        public OpenForReadResult(Uri uri, InputStream inputStream, String mimeType, long length, AssetFileDescriptor assetFd) {
            this.uri = uri;
            this.inputStream = inputStream;
            this.mimeType = mimeType;
            this.length = length;
            this.assetFd = assetFd;
        }
    }
}
