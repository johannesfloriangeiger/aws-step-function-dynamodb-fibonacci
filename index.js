exports.handler = async (event) => {
    return {
        'id': String(Number(event.id) + 1),
        'value': String(Number(event.first) + Number(event.second))
    }
};