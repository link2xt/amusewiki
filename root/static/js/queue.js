$(document).ready(function() {
    $('.nojs').hide();
});

function update_status(url, reloaded, offset) {
    if (!offset) {
        offset = 0;
    }
    // console.log(offset);
    $.getJSON(url, { 'offset':  offset }, function(data) {
        if (!reloaded) {
            $('.waiting-for-job').show();
        }
        $('pre#job-logs').append(data.logs);
        // console.log(data.logs);
        $('.bbstatusstring').text(data.status_loc);
        if (data.errors) {
            $('#job-errors').show().text(data.errors);
        }
        else {
            $('#job-errors').hide();
        }
        // recurse if pending or taken
        if ((data.status == 'pending') ||
            (data.status == 'taken')) {
            var funct = 'update_status("' + url + '", 1, ' + data.offset + ')';
            setTimeout(funct, 1000);
        }
        else {
            $('.waiting-for-job').hide();
        }
        if (data.position) {
            $('#task-lane').show();
            $('#lane').text(data.position);
        }
        else {
            $('#task-lane').hide();
        }
        if (data.status == 'completed') {
            $('a.completed').text(data.message);
            $('a.completed').attr('href', data.produced_uri);
            $('.completed').show();
            if (data.sources ) {
                $('a.sources').attr('href', data.sources);
                $('a.sources').show();
            }
        }
    });
};


