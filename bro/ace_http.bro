@load ace/ace_local.bro

const MAX_MESSAGE_SIZE = 1024 * 1024 * 10; # 10 MB maximum

type http_state_type: record {
    request_method: string &default=""; # The HTTP method extracted from the request
    request_original_URI: string &default=""; # The unprocessed URI as specified in the request.
    request_unescaped_URI: string &default=""; # The URI with all percent-encodings decoded.
    request_version: string &default=""; # The version number specified in the request 
    request_headers: vector of mime_header_rec &optional; # the list of submitted request headers

    reply_version: string &default=""; # The version number specified in the reply
    reply_code: count &default=0; # The numerical response code returned by the server.
    reply_reason: string &default=""; # The textual description returned by the server along with code.
    reply_headers: vector of mime_header_rec &optional; # the list of received request headers

    # keep track of what message we're on (a message is a full request/response)
    message_id: count &default=0;
    # keep track of how many bytes we've collected for this message
    message_size: count &default=0;
    
    # are we extracting the entities of either the request or the response?
    extracting_request: bool &default=F;
    extracting_reply: bool &default=F;
};

redef record connection += {
    ace_http_state: http_state_type &optional;
};

function get_target_http_filename(c: connection): string {
    return fmt("%s/%s.%d", bro_http_dir, c$uid, c$ace_http_state$message_id);
}

event http_request(c: connection, method: string, original_URI: string, unescaped_URI: string, version: string) {
    if (! c?$ace_http_state)
        c$ace_http_state = http_state_type();

    c$ace_http_state$request_method = method;
    c$ace_http_state$request_original_URI = original_URI;
    c$ace_http_state$request_unescaped_URI = unescaped_URI;
    c$ace_http_state$request_version = version;
    c$ace_http_state$request_headers = vector();
}

event http_reply(c: connection, version: string, code: count, reason: string) {
    c$ace_http_state$reply_version = version;
    c$ace_http_state$reply_code = code;
    c$ace_http_state$reply_reason = reason;
    c$ace_http_state$reply_headers = vector();
}

event http_header(c: connection, is_orig: bool, name: string, value: string) {
    if (is_orig) {
        c$ace_http_state$request_headers[|c$ace_http_state$request_headers|] = [$name=name, $value=value];
    } else {
        c$ace_http_state$reply_headers[|c$ace_http_state$reply_headers|] = [$name=name, $value=value];
    }
}

# request entity data (post data)
event http_entity_data(c: connection, is_orig: bool, length: count, data: string) {
    local f: file;
    local i: count;

    if (! is_orig)
        return;

    # is this the first chunk of data received?
    if (c$ace_http_state$message_size == 0) {
        # should we record this message?
        c$ace_http_state$extracting_request = record_http_stream(c, data);

    }

    # move the size counter up
    c$ace_http_state$message_size += length;

    # have we stopped extracting this entity data?
    if (! c$ace_http_state$extracting_request) 
        return;

    # is this entity too big?
    if (c$ace_http_state$message_size > MAX_MESSAGE_SIZE) {
        # cancel the extraction
        c$ace_http_state$extracting_request = F;
        # and delete any files we've created so far
        unlink(fmt("%s.request", get_target_http_filename(c)));
        unlink(fmt("%s.request.entity", get_target_http_filename(c)));
        return;
    }

    # otherwise we're extracting the message
    f = open_for_append(fmt("%s.request.entity", get_target_http_filename(c)));
    write_file(f, data);
    close(f);
}

# reply entity data
event http_entity_data(c: connection, is_orig: bool, length: count, data: string) {
    local f: file;
    local i: count;

    if (is_orig)
        return;

    # is this the first chunk of data received?
    if (c$ace_http_state$message_size == 0) {
        # should we record this message?
        c$ace_http_state$extracting_reply = record_http_stream(c, data);
    }

    # move the size counter up
    c$ace_http_state$message_size += length;

    # have we stopped extracting this entity data?
    if (! c$ace_http_state$extracting_reply) 
        return;

    # is this entity too big?
    if (c$ace_http_state$message_size > MAX_MESSAGE_SIZE) {
        # cancel the extraction
        c$ace_http_state$extracting_reply = F;
        # and delete any files we've created so far
        unlink(fmt("%s.reply", get_target_http_filename(c)));
        unlink(fmt("%s.reply.entity", get_target_http_filename(c)));
        return;
    }

    # otherwise we're extracting the entity
    f = open_for_append(fmt("%s.reply.entity", get_target_http_filename(c)));
    write_file(f, data);
    close(f);
}

# end request or reply entity data
event http_end_entity(c: connection, is_orig: bool) {
    c$ace_http_state$message_size = 0;
}

# called at the end of each request and reply
event http_message_done(c: connection, is_orig: bool, stat: http_message_stat) {
    local f: file;

    if (is_orig)
        return;

    # did we extract an entity from either side?
    if (c$ace_http_state$extracting_request || c$ace_http_state$extracting_reply) {
        # save request information
        f = open_for_append(fmt("%s.request", get_target_http_filename(c)));
        write_file(f, fmt("%s\n%s\n%s\n%s\n%s\n", 
                          c$id$orig_h,
                          c$ace_http_state$request_method, 
                          c$ace_http_state$request_original_URI, 
                          c$ace_http_state$request_unescaped_URI, 
                          c$ace_http_state$request_version));

        for (i in c$ace_http_state$request_headers)
            write_file(f, fmt("%s\t%s\n", c$ace_http_state$request_headers[i]$name, c$ace_http_state$request_headers[i]$value));

        close(f);

        # save reply information
        f = open_for_append(fmt("%s.reply", get_target_http_filename(c)));
        write_file(f, fmt("%s\t%d\n%s\n%s\n%s\n", 
                          c$id$resp_h,
                          c$id$resp_p,
                          c$ace_http_state$reply_version, 
                          c$ace_http_state$reply_code, 
                          c$ace_http_state$reply_reason));

        for (i in c$ace_http_state$reply_headers)
            write_file(f, fmt("%s\t%s\n", c$ace_http_state$reply_headers[i]$name, c$ace_http_state$reply_headers[i]$value));

        close(f);

        # mark the conversation as ready to be analyzed
        f = open_for_append(fmt("%s.ready", get_target_http_filename(c)));
        write_file(f, fmt("time = %s\ninterrupted = %s\nfinish_msg = %s\nbody_length = %d\ncontent_gap_length = %d\nheader_length = %d\n",
                          stat$start,
                          stat$interrupted,
                          stat$finish_msg,
                          stat$body_length,
                          stat$content_gap_length,
                          stat$header_length));
        close(f);
    }

    # move on to the next message
    c$ace_http_state$message_id += 1;
    c$ace_http_state$message_size = 0;
    c$ace_http_state$extracting_request = F;
    c$ace_http_state$extracting_reply = F;

}
